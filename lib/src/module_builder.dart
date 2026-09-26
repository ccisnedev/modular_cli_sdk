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
import 'invocation_outcome.dart';
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
    required Map<String, CommandContract> shortcutContractsByExactRoute,
    required Map<String, List<CommandContract>> shortcutContractsByPrefix,
    Approver? approver,
    PlanSink? planSink,
  }) : _router = router,
       _catalog = catalog,
       _bodiesByName = bodiesByName,
       _shortcutContractsByExactRoute = shortcutContractsByExactRoute,
       _shortcutContractsByPrefix = shortcutContractsByPrefix,
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

  /// Every shortcut's own contract, keyed by `cli_router`'s own
  /// `route.pattern` identity: mount prefix included, a trailing optional
  /// positional or wildcard stripped, a required one kept. Shared with
  /// every other [ModuleBuilder] this SDK builds, so [ModularCli] can find
  /// exactly one shortcut's contract for a rejection that names a specific
  /// route, even though a shortcut is deliberately given no [_catalog]
  /// entry of its own. See [ModularCli._shortcutContractFor].
  ///
  /// A second shortcut registering under the same mounted router pattern
  /// as one already here is a registration error (round-6 review finding
  /// 4): unlike [_shortcutContractsByPrefix], where several shortcuts
  /// legitimately share a prefix, this identity is meant to name exactly
  /// one route, and a collision here means two shortcuts would answer to
  /// the same `cli_router`-reported identity, which nothing could then
  /// tell apart.
  final Map<String, CommandContract> _shortcutContractsByExactRoute;

  /// Every shortcut's own contract, keyed by its mounted **literal prefix**
  /// alone (mount prefix included, every positional dropped, never a
  /// trailing space when the prefix itself is empty: see [_joinMounted]).
  /// This is the identity [CliRejection.consumed] reports when
  /// `cli_router` never resolved a specific route at all. Several
  /// shortcuts can share a literal prefix (`s` and `s <id>` are both
  /// prefixed `s`), so this maps to every candidate registered under it,
  /// not to one; [ModularCli._shortcutContractFor] reports back whether
  /// exactly one candidate matched or several did, rather than an earlier
  /// design's single shared map silently letting the later registration
  /// overwrite the earlier one (round-6 review finding 4).
  final Map<String, List<CommandContract>> _shortcutContractsByPrefix;
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
  /// runs with `program` looked up on the target and rebound `required`
  /// (the shorter spelling has no `[...]`) even though the target's own
  /// declaration of it is optional; the call still names its own
  /// [contract] explicitly ([CliContract.none] when it declares nothing),
  /// the same way [query] and [command] do: a route's contract is never
  /// left for a default to fill in silently.
  ///
  /// When [target] is a [Command], [contract] gains [ChangeFlags.params]
  /// exactly as [command] itself gains them: a shortcut to a route that
  /// changes something is still a route that changes something, and it
  /// cannot be invoked without choosing `--plan` or `--apply` any more
  /// than the target could. A shortcut to a [Query] gains nothing beyond
  /// what [contract] itself declares.
  ///
  /// Throws [ArgumentError] when [target] names no registered route, more
  /// than one (a shortcut's target must be unambiguous), when [contract]
  /// declares any positional itself, or when [pattern] names a positional
  /// [target] does not declare.
  void shortcut(
    String pattern, {
    required String target,
    required bool globals,
    required CliContract contract,
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

    final withChangeFlags = targetEntry.kind == CommandKind.command
        ? contract.withOptions(ChangeFlags.params)
        : contract;
    final shortcutContract = CliContract(
      options: withChangeFlags.options,
      positionals: derivedPositionals,
      constraints: withChangeFlags.constraints,
    );
    validateContractPositionals(pattern, shortcutContract);

    // Mount-prefixed exactly as [_register] prefixes a query's or
    // command's own [CommandContract.route] (round-6 review finding 6: an
    // earlier draft kept the bare, unprefixed [pattern] here, so a
    // resolved shortcut invocation's own `--help` answer, rendered by
    // [_mount] straight off this [entry], showed the bare pattern instead
    // of the route a caller actually has to type when the shortcut is
    // mounted under a module).
    final entry = CommandContract(
      route: moduleName.isEmpty ? pattern : '$moduleName $pattern',
      module: moduleName,
      kind: targetEntry.kind,
      description: description,
      contract: shortcutContract,
      globals: globals,
    );

    // Not registered with [_catalog] (see this method's own doc comment,
    // "deliberately not given its own CommandCatalog entry"), but kept
    // here, across two maps, so [ModularCli] can still validate a badly
    // typed supplied value against a shortcut's own contract before
    // letting `--help` win a rejection (round-4 review finding 1), and
    // report an ambiguous partial match honestly rather than guessing
    // (round-6 review finding 4).
    //
    // A `CliRejection` reports one of two identities: `route.pattern`,
    // `cli_router`'s own identity for a specific route it did resolve
    // (mount prefix included, a trailing optional positional or wildcard
    // stripped, a required one kept), or, when no specific route resolved
    // at all, `consumed`, the literal words alone (a parameter's bound
    // value, required or optional, is never in there; grammar G puts
    // every literal before every parameter, so there is exactly one
    // literal run, at the front). Both identities are mount-prefixed here
    // via [_joinMounted], which also fixes the second one's own bug
    // (round-6 review finding 5): a shortcut with no literal words at all
    // (`<id>` at the root, or `<id>` mounted under a module) has an empty
    // [RoutePattern.literalPrefix], and naive string concatenation
    // (`'$moduleName ${routePattern.literalPrefix}'`) left a trailing
    // space in the registered key that [CliRejection.consumed]'s own
    // `.join(' ')` (`['m'].join(' ')`, no trailing space) never produces,
    // so the key was never reachable at all; [_joinMounted] omits the
    // separator instead of leaving an empty segment on either side.
    //
    // [_shortcutContractsByExactRoute] names exactly one shortcut per
    // mounted router pattern, so a second registration under the same one
    // is a build-time [ArgumentError] rather than a later registration
    // silently overwriting an earlier one (round-6 review finding 4: a
    // single shared map let a positional shortcut like `s <id>` and a
    // bare one like `s` collide, since the bare one's own exact key and
    // the positional one's own prefix key were the same string).
    // [_shortcutContractsByPrefix] is not that kind of map: several
    // shortcuts legitimately share one literal prefix, so it collects
    // every candidate under it, and [ModularCli._shortcutContractFor]
    // decides, at lookup time, whether that is one candidate or several.
    final mountedRouterPattern = _joinMounted(
      moduleName,
      routePattern.routerPattern,
    );
    final mountedLiteralPrefix = _joinMounted(
      moduleName,
      routePattern.literalPrefix,
    );
    final existing = _shortcutContractsByExactRoute[mountedRouterPattern];
    if (existing != null) {
      throw ArgumentError(
        'shortcut("$pattern") registers under the mounted router pattern '
        '"$mountedRouterPattern", which shortcut("${existing.route}") '
        'already registered. Two shortcuts cannot share the identity '
        'cli_router itself would resolve one of them to; give one of '
        'them a different pattern.',
      );
    }
    _shortcutContractsByExactRoute[mountedRouterPattern] = entry;
    (_shortcutContractsByPrefix[mountedLiteralPrefix] ??= []).add(entry);

    _mount(
      pattern,
      entry,
      globals: globals,
      (req, output) => body(req, output, entry),
    );
  }

  /// Joins a module prefix and a route's own literal-word string the same
  /// way `cli_router` reports them back together on a [CliRejection]
  /// (`moduleName` then the route's own words, space-separated), without
  /// ever leaving a stray leading, trailing or doubled space when either
  /// half is empty (round-6 review finding 5): `_joinMounted('m', 's')`
  /// is `'m s'`, `_joinMounted('', 's')` is `'s'`, and, the case naive
  /// `'$moduleName $suffix'` concatenation got wrong,
  /// `_joinMounted('m', '')` is `'m'`, not `'m '`.
  static String _joinMounted(String moduleName, String suffix) {
    if (moduleName.isEmpty) return suffix;
    if (suffix.isEmpty) return moduleName;
    return '$moduleName $suffix';
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
        output.writeError(
          CommandException(
            id: 'approval-refused',
            message: declined.reason,
            exitCode: declined.exitCode,
            details: {'reason': declined.reason},
          ),
        );
        return declined.exitCode;
      }
    }

    final execution = await executor.perform(steps);
    final result = unit.describe(execution);
    final discrepancies = execution.discrepancies;
    final succeeded = execution.failure == null;

    // What the run did that it had not said it would. Written whatever the
    // command chose to report: it is the SDK's promise that was broken, not
    // the command's, and a reader must not have to take the command's word
    // for it.
    //
    // Under --json, a discrepancy is never written as raw "! ..." text:
    // --json's promise is that every write is one decodable JSON document,
    // and raw text ahead of a later JSON write (the result below, or the
    // failure envelope further down) would break that. It travels inside
    // the structured envelope instead: folded into the result object below
    // when the run went on to succeed, or into the failure envelope further
    // down when it did not.
    final isJsonMode = req.flagBool('json');
    if (isJsonMode && discrepancies.isNotEmpty && succeeded) {
      output.writeObject({
        ...result.toJson(),
        'discrepancies': [for (final d in discrepancies) d.toJson()],
      }, textOverride: result.toText());
    } else {
      output.writeObject(result.toJson(), textOverride: result.toText());
      if (!isJsonMode) {
        for (final discrepancy in discrepancies) {
          req.stderr.writeln('! ${discrepancy.message}');
        }
      }
    }

    if (execution.failure != null) {
      final thrown = execution.failure!.error;
      // A step that threw its own CommandException keeps that error exactly:
      // its id and exit code are the most specific thing known about the
      // failure, and re-wrapping it would throw that away. Anything else is
      // wrapped in a fixed, kebab-case id, so a --json caller always gets the
      // same envelope shape regardless of what the step actually threw.
      final baseException = thrown is CommandException
          ? thrown
          : CommandException(
              id: 'step-failed',
              message: execution.failure!.message,
              exitCode: result.exitCode == ExitCode.ok
                  ? ExitCode.genericError
                  : result.exitCode,
            );
      // In --json mode, a discrepancy that led up to this failure travels
      // in the failure envelope itself, since it is the only JSON document
      // stderr gets to carry it in.
      final exception = (isJsonMode && discrepancies.isNotEmpty)
          ? CommandException(
              id: baseException.id,
              message: baseException.message,
              exitCode: baseException.exitCode,
              details: {
                ...?baseException.details,
                'discrepancies': [for (final d in discrepancies) d.toJson()],
              },
            )
          : baseException;
      output.writeError(exception);
      // Stopping halfway is a failure of the invocation even when the command
      // found something to report about the part that ran.
      return exception.exitCode;
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
      // Round-8 review finding 2: this handler no longer resets the
      // recorded-error slot itself. Whenever it runs behind a middleware
      // (ModularCli.use()), that middleware's own guarded `next()` already
      // pushed a fresh InvocationOutcome frame right before calling into
      // here, so this handler always starts clean regardless of any
      // retry; with no middleware at all, it runs in the base frame
      // ModularCli.run()'s own runWithInvocationOutcome() call created
      // fresh for this dispatch. Either way, a superseded retry's error
      // cannot outlive it: only what this attempt itself goes on to
      // record, if anything, is left for the frame above to read back.
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
        validateSuppliedOptionValues(req.options, entry.contract);
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

  /// A rejected invocation is answered with the contract it failed to
  /// honour: the user was one flag away from succeeding. Neither this nor
  /// [CliOutput.writeError] writes anything itself any more: both only
  /// record, into the current invocation's own [InvocationOutcome]
  /// (round-6 review findings 1 through 3), what [ModularCli.run] alone
  /// renders, exactly once, after the whole dispatch finishes.
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
      recordInvocationExtraText(HelpRenderer(_catalog).renderCommand(entry));
    }
    return error.exitCode;
  }
}
