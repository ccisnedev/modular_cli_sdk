import 'package:cli_router/cli_router.dart';

import 'cli_output.dart';
import 'cli_output_json.dart';
import 'cli_output_text.dart';
import 'cli_param.dart';
import 'command.dart';
import 'command_catalog.dart';
import 'command_exception.dart';
import 'declared_arguments.dart';
import 'exit_codes.dart';
import 'help_renderer.dart';
import 'input.dart';
import 'output.dart';

/// Registers [Command]s within a named module.
///
/// Analogous to `ModuleBuilder` in modular_api — but the transport is
/// CLI args instead of HTTP requests.
///
/// Each [command] call wires a factory function into a `CliRouter` route.
/// The generated handler runs the full Command lifecycle:
///   1. Build `Input` from `CliRequest` (via the factory)
///   2. Build `Command` from `Input` (via the factory)
///   3. `validate()` — abort with exit code 7 if invalid
///   4. `execute()` — run business logic
///   5. Format `Output` through the active [CliOutput]
///
/// ```dart
/// cli.module('greetings', (m) {
///   m.command('hello', (req) => GreetCommand(GreetInput.fromCliRequest(req)),
///     description: 'Say hello');
/// });
/// ```
class ModuleBuilder {
  ModuleBuilder({
    required this.moduleName,
    required CliRouter router,
    required CommandCatalog catalog,
  }) : _router = router,
       _catalog = catalog;

  /// Name of the module (used as the mount prefix).
  final String moduleName;

  final CliRouter _router;
  final CommandCatalog _catalog;

  /// Register a command within this module.
  ///
  /// [route] — sub-route within the module (e.g. `'list'`, `'show <id>'`).
  /// [commandFactory] — builds a fully-initialized Command from a CliRequest.
  ///   The factory is responsible for constructing both Input and Command.
  /// [description] — one-line help text shown in `printHelp`.
  /// [params] — the command's declared contract, usually the `params` of its
  ///   [Input]. Declaring it publishes the command in help and enforces the
  ///   parameters at parse time; omitting it leaves both behaviours off.
  void command<I extends Input, O extends Output>(
    String route,
    Command<I, O> Function(CliRequest req) commandFactory, {
    String? description,
    List<CliParam> params = const [],
  }) {
    final contract = CommandContract(
      route: moduleName.isEmpty ? route : '$moduleName $route',
      module: moduleName,
      description: description,
      params: params,
    );
    _catalog.register(contract);

    _router.cmd(route, (req) async {
      final isJsonMode = req.flagBool('json');
      final isQuiet = req.flagBool('quiet', aliases: const ['q']);

      final CliOutput output = isJsonMode
          ? JsonCliOutput(
              stdout: req.stdout,
              stderr: req.stderr,
              isQuiet: isQuiet,
            )
          : TextCliOutput(
              stdout: req.stdout,
              stderr: req.stderr,
              isQuiet: isQuiet,
            );

      // Asked for the contract, not for the work: help before enforcement, so
      // `--help` on an incomplete invocation helps instead of failing.
      if (req.flagBool('help', aliases: const ['h'])) {
        output.writeObject(
          contract.toJson(),
          textOverride: HelpRenderer(_catalog).renderCommand(contract),
        );
        return ExitCode.ok;
      }

      return _executeCommand(
        req,
        commandFactory,
        output,
        contract,
        showsContractOnRejection: !isJsonMode,
      );
    }, description: description);
  }

  /// Run the Command lifecycle and return an exit code.
  Future<int> _executeCommand<I extends Input, O extends Output>(
    CliRequest req,
    Command<I, O> Function(CliRequest) commandFactory,
    CliOutput cliOutput,
    CommandContract contract, {
    required bool showsContractOnRejection,
  }) async {
    try {
      // The declared contract is applied before the Input reads a single flag,
      // so help and runtime can never describe different commands.
      final cmd = commandFactory(applyDeclaredContract(req, contract.params));

      final validationError = cmd.validate();
      if (validationError != null) {
        return _reject(
          CommandException(
            code: 'VALIDATION_FAILED',
            message: validationError,
            exitCode: ExitCode.validationFailed,
          ),
          req,
          cliOutput,
          contract,
          showsContractOnRejection: showsContractOnRejection,
        );
      }

      final commandOutput = await cmd.execute();
      cliOutput.writeObject(
        commandOutput.toJson(),
        textOverride: commandOutput.toText(),
      );
      return commandOutput.exitCode;
    } on CommandException catch (e) {
      return _reject(
        e,
        req,
        cliOutput,
        contract,
        showsContractOnRejection: showsContractOnRejection,
      );
    }
  }

  /// A rejected invocation is answered with the contract it failed to honour —
  /// the user was one flag away from succeeding.
  int _reject(
    CommandException error,
    CliRequest req,
    CliOutput cliOutput,
    CommandContract contract, {
    required bool showsContractOnRejection,
  }) {
    cliOutput.writeError(error);
    if (showsContractOnRejection &&
        error.exitCode == ExitCode.validationFailed) {
      req.stderr
        ..writeln()
        ..writeln(HelpRenderer(_catalog).renderCommand(contract));
    }
    return error.exitCode;
  }
}
