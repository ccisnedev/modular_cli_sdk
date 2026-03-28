import 'package:cli_router/cli_router.dart';

import 'cli_output.dart';
import 'cli_output_json.dart';
import 'cli_output_text.dart';
import 'command.dart';
import 'command_exception.dart';
import 'exit_codes.dart';
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
  ModuleBuilder({required this.moduleName, required CliRouter router})
    : _router = router;

  /// Name of the module (used as the mount prefix).
  final String moduleName;

  final CliRouter _router;

  /// Register a command within this module.
  ///
  /// [route] — sub-route within the module (e.g. `'list'`, `'show <id>'`).
  /// [commandFactory] — builds a fully-initialized Command from a CliRequest.
  ///   The factory is responsible for constructing both Input and Command.
  /// [description] — one-line help text shown in `printHelp`.
  void command<I extends Input, O extends Output>(
    String route,
    Command<I, O> Function(CliRequest req) commandFactory, {
    String? description,
  }) {
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

      return _executeCommand(req, commandFactory, output);
    }, description: description);
  }

  /// Run the Command lifecycle and return an exit code.
  Future<int> _executeCommand<I extends Input, O extends Output>(
    CliRequest req,
    Command<I, O> Function(CliRequest) commandFactory,
    CliOutput cliOutput,
  ) async {
    try {
      final cmd = commandFactory(req);

      final validationError = cmd.validate();
      if (validationError != null) {
        cliOutput.writeError(
          CommandException(
            code: 'VALIDATION_FAILED',
            message: validationError,
            exitCode: ExitCode.validationFailed,
          ),
        );
        return ExitCode.validationFailed;
      }

      final commandOutput = await cmd.execute();
      cliOutput.writeObject(commandOutput.toJson());
      return commandOutput.exitCode;
    } on CommandException catch (e) {
      cliOutput.writeError(e);
      return e.exitCode;
    }
  }
}
