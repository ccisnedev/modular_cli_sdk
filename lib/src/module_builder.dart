import 'package:cli_router/cli_router.dart';
import 'package:preview_executor/preview_executor.dart';

import 'approver.dart';
import 'change_flags.dart';
import 'change_outputs.dart';
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
import 'plan.dart';
import 'query.dart';

/// Registers [Query]s and [Command]s within a named module.
///
/// Analogous to `ModuleBuilder` in modular_api — but the transport is CLI args
/// instead of HTTP requests.
///
/// Which of the two a route is registered as decides what the framework does
/// with it, so "this changes something" is a fact about the registration rather
/// than a comment in the file:
///
/// ```dart
/// cli.module('requisition', (m) {
///   m.query('list', (req) => ListRequisitions(...));      // no --plan/--apply
///   m.command('new <slug>', (req) => OpenRequisition(...)); // both, declared
/// });
/// ```
class ModuleBuilder {
  ModuleBuilder({
    required this.moduleName,
    required CliRouter router,
    required CommandCatalog catalog,
    Approver? approver,
    PlanSink? planSink,
  }) : _router = router,
       _catalog = catalog,
       _approver = approver,
       _planSink = planSink;

  /// Name of the module (used as the mount prefix).
  final String moduleName;

  final CliRouter _router;
  final CommandCatalog _catalog;
  final Approver? _approver;
  final PlanSink? _planSink;

  /// Register a [Query] — a route that reads and answers.
  ///
  /// It is not given `--plan` or `--apply`, and passing either is rejected as
  /// the undeclared option it is. Nothing has to be written to make that true.
  void query<I extends Input, O extends Output>(
    String route,
    Query<I, O> Function(CliRequest req) queryFactory, {
    String? description,
    List<CliParam>? params,
  }) {
    final contract = _register(
      route,
      kind: CommandKind.query,
      description: description,
      params: params,
    );

    _mount(route, contract, description, (req, output) async {
      final unit = queryFactory(applyDeclaredContract(req, contract.params));

      final invalid = unit.validate();
      if (invalid != null) throw _rejection(invalid);

      final result = await unit.execute();
      output.writeObject(result.toJson(), textOverride: result.toText());
      return result.exitCode;
    });
  }

  /// Register a [Command] — a route that changes something.
  ///
  /// `--plan`, `--apply` and `--autoapprove` are appended to whatever the
  /// command declared, and their rules are applied before a single step is
  /// built. The author writes none of that.
  ///
  /// Unlike [query], a command is **always** enforced: omitting [params] does
  /// not leave it undeclared, it declares that the command takes nothing but
  /// the three flags. A route that changes something cannot be the one whose
  /// arguments nobody checks, and the flags have to be declared to be typed at
  /// all.
  void command<I extends Input, O extends Output>(
    String route,
    Command<I, O> Function(CliRequest req) commandFactory, {
    String? description,
    List<CliParam>? params,
  }) {
    final contract = _register(
      route,
      kind: CommandKind.command,
      description: description,
      // A command that declared nothing stays unenforced, as before — but it
      // still gets the three flags, because it cannot be invoked without one.
      params: [...?params, ...ChangeFlags.params],
    );

    _mount(route, contract, description, (req, output) async {
      final applied = applyDeclaredContract(req, contract.params);
      final unit = commandFactory(applied);

      final invalid = unit.validate();
      if (invalid != null) throw _rejection(invalid);

      final flags = ChangeFlags.fromCliRequest(applied);
      final unusable = flags.validate();
      if (unusable != null) throw _rejection(unusable);

      return _carryOut(unit, flags, contract, output, req);
    });
  }

  // ── The lifecycle of a command ────────────────────────────────────────────

  /// Build the steps, ask them what they would do, and then either stop or act.
  ///
  /// The steps are built **once** and previewed **once**. Under `--apply` the
  /// executor previews each step again immediately before performing it and
  /// compares the two, so what a person approved and what the run did are held
  /// together by the engine rather than by everyone remembering.
  Future<int> _carryOut<I extends Input, O extends Output>(
    Command<I, O> unit,
    ChangeFlags flags,
    CommandContract contract,
    CliOutput output,
    CliRequest req,
  ) async {
    const executor = PreviewExecutor();

    final steps = await unit.steps();
    final plan = PlanDocument(
      route: contract.name,
      previews: executor.preview(steps),
    );

    if (flags.mode == ChangeMode.plan) {
      final filed = _planSink?.call(plan);
      final planned = PlanOutput(plan, filedAt: filed);
      output.writeObject(planned.toJson(), textOverride: planned.toText());
      return planned.exitCode;
    }

    if (!flags.autoapprove) {
      final declined = await _refusalOf(plan);
      if (declined != null) {
        output.writeObject(declined.toJson(), textOverride: declined.toText());
        return declined.exitCode;
      }
    }

    final execution = await executor.perform(steps);
    final result = unit.describe(execution);

    output.writeObject(result.toJson(), textOverride: result.toText());

    // What the run did that it had not said it would. Written whatever the
    // command chose to report: it is the SDK's promise that was broken, not the
    // command's, and a reader must not have to take the command's word for it.
    for (final discrepancy in execution.discrepancies) {
      req.stderr.writeln('! ${discrepancy.message}');
    }
    if (execution.failure != null) {
      req.stderr.writeln('! ${execution.failure!.message}');
      // Stopping halfway is a failure of the invocation even when the command
      // found something to report about the part that ran.
      return result.exitCode == ExitCode.ok
          ? ExitCode.genericError
          : result.exitCode;
    }

    return result.exitCode;
  }

  /// Null when the plan may be carried out; the answer to write when it may not.
  Future<DeclinedOutput?> _refusalOf(PlanDocument plan) async {
    final approver = _approver ?? ConsoleApprover().call;
    try {
      return await approver(plan.text)
          ? null
          : DeclinedOutput('Not applied. Nothing was changed.');
    } on NoApproverAvailable catch (e) {
      return DeclinedOutput(e.message);
    }
  }

  // ── Registration plumbing, shared by both kinds ───────────────────────────

  CommandContract _register(
    String route, {
    required CommandKind kind,
    required String? description,
    required List<CliParam>? params,
  }) {
    final contract = CommandContract(
      route: moduleName.isEmpty ? route : '$moduleName $route',
      module: moduleName,
      kind: kind,
      description: description,
      params: params,
    );
    _catalog.register(contract);
    return contract;
  }

  /// Wire the route: choose the output mode, answer `--help`, and run [body]
  /// with the errors of either kind turned into the same rejection.
  void _mount(
    String route,
    CommandContract contract,
    String? description,
    Future<int> Function(CliRequest req, CliOutput output) body,
  ) {
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

      try {
        return await body(req, output);
      } on CommandException catch (e) {
        return _reject(
          e,
          req,
          output,
          contract,
          showsContractOnRejection: !isJsonMode,
        );
      }
    }, description: description);
  }

  CommandException _rejection(String message) => CommandException(
    code: 'VALIDATION_FAILED',
    message: message,
    exitCode: ExitCode.validationFailed,
  );

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
