import 'package:cli_router/cli_router.dart';
import 'package:preview_executor/preview_executor.dart';

import 'approver.dart';
import 'change_flags.dart';
import 'change_outputs.dart';
import 'cli_contract.dart';
import 'cli_output.dart';
import 'cli_output_json.dart';
import 'cli_output_text.dart';
import 'cli_positional.dart';
import 'cli_request_values.dart';
import 'command.dart';
import 'command_catalog.dart';
import 'command_exception.dart';
import 'declared_arguments.dart';
import 'exit_codes.dart';
import 'explains_nothing_to_do.dart';
import 'help_renderer.dart';
import 'input.dart';
import 'output.dart';
import 'plan.dart';
import 'query.dart';
import 'route_pattern.dart';

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
/// A route's business logic, reusable under a different [CommandContract]
/// than the one it was originally registered under.
///
/// [callingEntry] carries both the contract to apply the invocation against
/// (which may be a [ModularCli.shortcut]'s own, stricter contract, not the
/// target's) and the name to report as [PlanDocument.route] for a command:
/// dispatch always runs as whichever route the caller actually typed, never
/// silently as the route it happens to share logic with.
typedef ContractAwareBody =
    Future<int> Function(
      CliRequest req,
      CliOutput output,
      CommandContract callingEntry,
    );

class ModuleBuilder {
  ModuleBuilder({
    required this.moduleName,
    required CliRouter router,
    required CommandCatalog catalog,
    required Map<String, ContractAwareBody> bodiesByName,
    Approver? approver,
    PlanSink? planSink,
  }) : _router = router,
       _catalog = catalog,
       _bodiesByName = bodiesByName,
       _approver = approver,
       _planSink = planSink;

  /// Name of the module (used as the mount prefix).
  final String moduleName;

  final CliRouter _router;
  final CommandCatalog _catalog;

  /// Every registered route's own business logic, keyed by
  /// [CommandContract.route]: the exact pattern as registered, not the
  /// name with its positionals stripped, so `show` and `show <id>` (two
  /// different routes that happen to share a name) each keep their own
  /// entry instead of the second silently overwriting the first.
  ///
  /// Shared with every other [ModuleBuilder] this SDK builds (all backed by
  /// the same [ModularCli]), so [ModularCli.shortcut] can find a target
  /// route's logic regardless of which module registered it, and dispatch
  /// it under the shortcut's own contract rather than the target's.
  final Map<String, ContractAwareBody> _bodiesByName;
  final Approver? _approver;
  final PlanSink? _planSink;

  /// Register a [Query] — a route that reads and answers.
  ///
  /// It is not given `--plan` or `--apply`, and passing either is rejected as
  /// the undeclared option it is. Nothing has to be written to make that true.
  ///
  /// [contract] is required: a query that takes nothing declares that
  /// explicitly, with [CliContract.none], rather than an absent argument
  /// silently meaning the same thing.
  void query<I extends Input, O extends Output>(
    String route,
    Query<I, O> Function(CliRequest req) queryFactory, {
    required bool globals,
    required CliContract contract,
    String? description,
  }) {
    final entry = _register(
      route,
      kind: CommandKind.query,
      description: description,
      contract: contract,
      globals: globals,
    );

    Future<int> body(
      CliRequest req,
      CliOutput output,
      CommandContract callingEntry,
    ) async {
      final unit = queryFactory(
        applyDeclaredContract(req, callingEntry.contract),
      );

      final invalid = unit.validate();
      if (invalid != null) throw _rejection(invalid);

      final result = await unit.execute();
      output.writeObject(result.toJson(), textOverride: result.toText());
      return result.exitCode;
    }

    _bodiesByName[entry.route] = body;
    _mount(
      route,
      entry,
      globals: globals,
      (req, output) => body(req, output, entry),
    );
  }

  /// Register a [Command] — a route that changes something.
  ///
  /// `--plan`, `--apply` and `--autoapprove` are appended to whatever the
  /// command declared, and their rules are applied before a single step is
  /// built. The author writes none of that.
  ///
  /// Unlike [query], a command is **always** enforced against at least the
  /// three flags: [contract] gains them regardless of what it declares,
  /// because a route that changes something cannot be invoked without
  /// choosing one, and the flags have to be declared to be typed at all.
  /// [contract] itself is still required, for the same reason as [query]'s.
  void command<I extends Input, O extends Output>(
    String route,
    Command<I, O> Function(CliRequest req) commandFactory, {
    required bool globals,
    required CliContract contract,
    String? description,
  }) {
    final entry = _register(
      route,
      kind: CommandKind.command,
      description: description,
      contract: contract.withOptions(ChangeFlags.params),
      globals: globals,
    );

    Future<int> body(
      CliRequest req,
      CliOutput output,
      CommandContract callingEntry,
    ) async {
      final applied = applyDeclaredContract(req, callingEntry.contract);
      final unit = commandFactory(applied);

      final invalid = unit.validate();
      if (invalid != null) throw _rejection(invalid);

      final flags = ChangeFlags.fromCliRequest(applied);
      final unusable = flags.validate();
      if (unusable != null) throw _rejection(unusable);

      return _carryOut(unit, flags, callingEntry, output, req);
    }

    _bodiesByName[entry.route] = body;
    _mount(
      route,
      entry,
      globals: globals,
      (req, output) => body(req, output, entry),
    );
  }

  /// Registers [pattern] as a route that runs the same business logic
  /// already registered for [target] (the full name of a route already
  /// registered via [query], [command] or another [ModuleBuilder], e.g.
  /// `'eval rpn'`), but dispatched through [pattern]'s own, independently
  /// declared [contract] (types, defaults, constraints) and [globals]
  /// scope, never the target's (issue #27 section 4: "a declared route
  /// that runs the target's handler with a narrower contract").
  ///
  /// [contract] must declare only options and constraints: a shortcut's
  /// positionals are not declared by the caller but taken from [target]'s
  /// own positional declarations, matched by name, and bound to whichever
  /// cardinality [pattern] itself gives them. The exact line from issue
  /// #27, `shortcut('<program>', target: 'eval rpn', globals: false)`,
  /// works with no explicit [contract] at all, because `program` is looked
  /// up on the target and rebound `required` (the shorter spelling has no
  /// `[...]`) even though the target's own declaration of it is optional.
  ///
  /// Throws [ArgumentError] when [target] names no registered route, more
  /// than one (a shortcut's target must be unambiguous), when [contract]
  /// declares any positional itself, or when [pattern] names a positional
  /// [target] does not declare.
  void shortcut(
    String pattern, {
    required String target,
    required bool globals,
    CliContract contract = CliContract.none,
    String? description,
  }) {
    final matches = _catalog.commands.where((c) => c.name == target).toList();
    if (matches.isEmpty) {
      throw ArgumentError(
        'shortcut("$pattern") targets "$target", which is not a '
        'registered route. Register the target with query(), command() or '
        'a ModuleBuilder before declaring a shortcut to it.',
      );
    }
    if (matches.length > 1) {
      throw ArgumentError(
        'shortcut("$pattern") targets "$target", which is ambiguous: it '
        'matches more than one registered route '
        '(${matches.map((c) => c.route).join(', ')}).',
      );
    }
    if (contract.positionals.isNotEmpty) {
      throw ArgumentError(
        'shortcut("$pattern") declares positional(s) directly in its own '
        'contract (${contract.positionals.map((p) => p.name).join(', ')}). '
        'A shortcut\'s positionals are taken from its target ("$target") '
        'automatically, by name; declare none here.',
      );
    }

    final targetEntry = matches.single;
    final body = _bodiesByName[targetEntry.route];
    if (body == null) {
      // Every catalog entry gets a body registered alongside it, in the
      // same call, so this would be an inconsistency in this SDK itself.
      throw StateError(
        'shortcut("$pattern") found no dispatch body for "$target".',
      );
    }

    final routePattern = RoutePattern(pattern);
    final derivedPositionals = [
      for (final name in routePattern.positionals)
        _positionalFromTarget(targetEntry, name, pattern, target, routePattern),
    ];

    final shortcutContract = CliContract(
      options: contract.options,
      positionals: derivedPositionals,
      constraints: contract.constraints,
    );
    validateContractPositionals(pattern, shortcutContract);

    final entry = CommandContract(
      route: pattern,
      module: moduleName,
      kind: targetEntry.kind,
      description: description,
      contract: shortcutContract,
      globals: globals,
    );

    _mount(
      pattern,
      entry,
      globals: globals,
      (req, output) => body(req, output, entry),
    );
  }

  CliPositional _positionalFromTarget(
    CommandContract targetEntry,
    String name,
    String pattern,
    String target,
    RoutePattern routePattern,
  ) {
    for (final positional in targetEntry.contract.positionals) {
      if (positional.name == name) {
        return positional.withRequired(
          routePattern.requiredPositionals.contains(name),
        );
      }
    }
    throw ArgumentError(
      'shortcut("$pattern") declares positional "<$name>" but its target '
      '("$target") declares no positional of that name.',
    );
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
    CommandContract entry,
    CliOutput output,
    CliRequest req,
  ) async {
    const executor = PreviewExecutor();

    final steps = await unit.steps();
    final plan = PlanDocument(
      route: entry.name,
      previews: executor.preview(steps),
      // Read after steps(), which is where a command works out that it has
      // nothing to do and why. Consulted whatever the mode: the reason belongs
      // to --plan exactly as much as to --apply.
      nothingToDo: unit is ExplainsNothingToDo
          ? (unit as ExplainsNothingToDo).nothingToDo
          : null,
    );

    if (flags.mode == ChangeMode.plan) {
      final filed = _planSink?.call(plan);
      final planned = PlanOutput(plan, filedAt: filed);
      output.writeObject(planned.toJson(), textOverride: planned.toText());
      return planned.exitCode;
    }

    // Nothing to carry out, so nothing to approve. The approval exists to put a
    // change in front of a person before it happens; with no change there is no
    // question to ask, and asking it anyway was worse than noise — where no
    // terminal can answer, `--apply` failed a run that had nothing to do.
    if (plan.previews.isEmpty) {
      final nothing = NothingToDoOutput(plan);
      output.writeObject(nothing.toJson(), textOverride: nothing.toText());
      return nothing.exitCode;
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
    required CliContract contract,
    required bool globals,
  }) {
    // Build-time, not runtime: a route/contract mismatch (missing, extra,
    // misnamed, duplicate or wrongly-required/optional positional) is an
    // authoring mistake, caught the moment the route is declared, not
    // something a caller could ever trigger by what they typed.
    validateContractPositionals(route, contract);
    final entry = CommandContract(
      route: moduleName.isEmpty ? route : '$moduleName $route',
      module: moduleName,
      kind: kind,
      description: description,
      contract: contract,
      globals: globals,
    );
    _catalog.register(entry);
    return entry;
  }

  /// Wire the route: choose the output mode, answer `--help`, and run [body]
  /// with the errors of either kind turned into the same rejection.
  ///
  /// `cli_router` has already checked, before this handler ever runs, that
  /// every option present was declared, that every required one showed up,
  /// and that none repeated beyond what was declared: [entry.contract] is
  /// registered as this route's [OptionSpec]s below. What is left to this
  /// handler is picking the output mode, answering `--help` on a resolved
  /// invocation, and turning a [CommandException] into the same rejection
  /// shape whichever kind raised it.
  void _mount(
    String route,
    CommandContract entry,
    Future<int> Function(CliRequest req, CliOutput output) body, {
    required bool globals,
  }) {
    Future<int> handler(CliRequest req) async {
      final isJsonMode = req.flagBool('json');
      final isQuiet = req.flagBool('quiet');

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

      // A value the caller actually supplied is checked before `--help` is
      // even considered: unlike a missing required option (`cli_router`
      // itself refuses to resolve the invocation at all) or an unmet
      // constraint (only ever checked inside `body`, so it stays correctly
      // skipped below), a badly typed value is this SDK's own concern, and
      // nothing catches it before this point (issue #27 section 5: "help
      // loses to an option error").
      try {
        validateSuppliedOptionValues(req, entry.contract);
      } on CommandException catch (e) {
        return _reject(
          e,
          req,
          output,
          entry,
          showsContractOnRejection: !isJsonMode,
        );
      }

      // Asked for the contract, not for the work: help short-circuits a
      // resolved invocation before the handler itself ever runs, so
      // `--help` alongside other, well-typed options answers with the
      // contract rather than acting on it.
      if (req.flagBool('help')) {
        output.writeObject(
          entry.toJson(),
          textOverride: HelpRenderer(_catalog).renderCommand(entry),
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
          entry,
          showsContractOnRejection: !isJsonMode,
        );
      }
    }

    _router.cmd(
      route,
      handler,
      options: entry.contract.toOptionSpecs(),
      globals: globals,
      description: entry.description,
    );
  }

  CommandException _rejection(String message) => CommandException(
    id: 'validation-failed',
    message: message,
    exitCode: ExitCode.validationFailed,
  );

  /// A rejected invocation is answered with the contract it failed to honour —
  /// the user was one flag away from succeeding.
  int _reject(
    CommandException error,
    CliRequest req,
    CliOutput cliOutput,
    CommandContract entry, {
    required bool showsContractOnRejection,
  }) {
    cliOutput.writeError(error);
    if (showsContractOnRejection &&
        error.exitCode == ExitCode.validationFailed) {
      req.stderr
        ..writeln()
        ..writeln(HelpRenderer(_catalog).renderCommand(entry));
    }
    return error.exitCode;
  }
}
