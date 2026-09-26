import 'dart:convert';
import 'dart:io' as io;

import 'package:cli_router/cli_router.dart';

import 'approver.dart';
import 'cli_contract.dart';
import 'cli_request_values.dart';
import 'command.dart';
import 'command_catalog.dart';
import 'command_exception.dart';
import 'declared_arguments.dart';
import 'exit_codes.dart';
import 'global_options.dart';
import 'help_command.dart';
import 'help_renderer.dart';
import 'input.dart';
import 'invocation_outcome.dart';
import 'module_builder.dart';
import 'output.dart';
import 'plan.dart';
import 'query.dart';

/// Entry point for a modular CLI application.
///
/// Analogous to `ModularApi` in modular_api — orchestrates modules, applies
/// middleware, handles global flags (`--json`, `--quiet`), and dispatches
/// through `cli_router`.
///
/// Routes are registered as one of two kinds, and the kind decides what the
/// framework does with them: a [Query] reads and is refused `--plan` and
/// `--apply`; a [Command] changes something and is given both, plus the
/// approval that sits between them.
///
/// ```dart
/// final cli = ModularCli();
///
/// cli.query<VersionInput, VersionOutput>(
///   'version',
///   (req) => VersionQuery(VersionInput.fromCliRequest(req)),
///   description: 'Print version info',
/// );
///
/// cli.module('requisition', (m) {
///   m.query('list', (req) => ListRequisitions(...), description: '…');
///   m.command('new <slug>', (req) => OpenRequisition(...), description: '…');
/// });
///
/// final exitCode = await cli.run(args);
/// ```
class ModularCli {
  /// [approver] decides whether a plan shown by `--apply` may be carried out.
  /// Defaults to asking on the terminal, and refusing rather than hanging when
  /// there is no terminal to ask.
  ///
  /// [planSink] files the plan that `--plan` produces, and returns where it put
  /// it. Defaults to filing it nowhere: the plan is printed, and whether a
  /// project keeps plans on disk is that project's decision, not this SDK's.
  ///
  /// [suggestionDistance] is the maximum restricted edit distance a "did you
  /// mean" suggestion (both from [suggest] and from a rejected invocation's
  /// own error message) is allowed to be, in the sense
  /// [CommandCatalog.suggest] defines it. Required, not defaulted: how
  /// forgiving a typo suggestion should be is a fact about this CLI's own
  /// vocabulary (a CLI with many short, similar command words wants a
  /// tighter distance than one with few, long ones), not a number this SDK
  /// should assume silently.
  ModularCli({
    Approver? approver,
    PlanSink? planSink,
    required int suggestionDistance,
  }) : _approver = approver,
       _planSink = planSink,
       _suggestionDistance = suggestionDistance;

  final Approver? _approver;
  final PlanSink? _planSink;
  final int _suggestionDistance;

  late final CliRouter _root = CliRouter(globalOptions: globalOptionSpecs);
  final CommandCatalog _catalog = CommandCatalog();

  /// Every registered route's business logic, keyed by
  /// [CommandContract.route]. Shared by every [ModuleBuilder] this instance
  /// builds, so [shortcut] can find a target route's logic no matter which
  /// module registered it, and dispatch it under the shortcut's own
  /// contract. See [ContractAwareBody].
  final Map<String, ContractAwareBody> _bodiesByName = {};

  /// Every shortcut's own contract, keyed by `cli_router`'s own
  /// `route.pattern` identity: mount prefix included, a trailing optional
  /// positional or wildcard stripped, a required one kept. [_contractFor]
  /// (through [_catalog]) cannot see a shortcut at all (a shortcut is
  /// deliberately not given its own catalog entry: see [shortcut]'s own
  /// doc comment), so [_handleRejection] consults this too, to check a
  /// badly typed supplied value before letting `--help` win a rejection
  /// (round-4 review finding 1). A second shortcut registered under the
  /// same mounted router pattern as one already here is a build-time
  /// [ArgumentError], raised by [ModuleBuilder.shortcut] itself (round-6
  /// review finding 4: an earlier, single shared map let a later
  /// registration overwrite an earlier one silently instead).
  final Map<String, CommandContract> _shortcutContractsByExactRoute = {};

  /// Every shortcut's own contract, keyed by its mounted **literal prefix**
  /// alone (mount prefix included, every positional dropped): the identity
  /// [CliRejection.consumed] reports when `cli_router` never resolved a
  /// specific route at all. Several shortcuts can share one literal prefix
  /// (`s` and `s <id>` are both prefixed `s`), so this maps to every
  /// candidate registered under it, and [_applicableContractFor] reports
  /// back whether exactly one candidate matched or several did, rather
  /// than picking one arbitrarily (round-6 review finding 4) or letting
  /// `--help` win silently on an ambiguous partial match (round-6 review
  /// finding 6). See [ModuleBuilder.shortcut] for how both maps are kept
  /// in sync, including the empty-prefix fix (round-6 review finding 5).
  ///
  /// [_emitRejectionError] never consults either map directly: a shortcut's
  /// own contract still never shows up in a JSON error's `contract` field.
  /// [_emitFocusedHelp] is different since round-9 review finding 4: it
  /// renders whichever contract [_applicableContractFor] already resolved
  /// through these maps, a shortcut's own included, once resolution settled
  /// on exactly one candidate; only when nothing resolved (or resolution
  /// stayed genuinely ambiguous) does it fall back to looking outside these
  /// maps entirely, exactly as documented on [shortcut] itself.
  final Map<String, List<CommandContract>> _shortcutContractsByPrefix = {};

  /// Every registered route with its declared contract — the single source help
  /// is rendered from.
  CommandCatalog get catalog => _catalog;

  /// Register a named module with its routes.
  ///
  /// [name] becomes the first segment: `name subcommand`.
  ///
  /// An empty [name] is the CLI's own root: `cli.module('', (m) { ... })`
  /// registers its routes directly on the root router, exactly as
  /// top-level [query]/[command] calls do. `cli_router.mount` requires its
  /// prefix to be exactly one literal word, and `''` splits into zero, so
  /// an empty module is handled here, before `mount` is ever called,
  /// rather than by trying to mount under a prefix that cannot exist.
  ModularCli module(String name, void Function(ModuleBuilder) build) {
    if (name.isEmpty) {
      build(_builderFor('', _root));
      return this;
    }
    final moduleRouter = CliRouter(globalOptions: globalOptionSpecs);
    build(_builderFor(name, moduleRouter));
    _root.mount(name, moduleRouter);
    return this;
  }

  /// Register a root-level [Query] (no module prefix).
  ///
  /// [contract] is required: see [ModuleBuilder.query].
  ModularCli query<I extends Input, O extends Output>(
    String route,
    Query<I, O> Function(CliRequest req) queryFactory, {
    required bool globals,
    required CliContract contract,
    String? description,
  }) {
    _builderFor('', _root).query<I, O>(
      route,
      queryFactory,
      globals: globals,
      description: description,
      contract: contract,
    );
    return this;
  }

  /// Register a root-level [Command] (no module prefix).
  ///
  /// Root routes have dispatch priority over mounted modules (inherent to
  /// `cli_router`'s two-phase dispatch).
  ///
  /// [contract] is required: see [ModuleBuilder.command].
  ModularCli command<I extends Input, O extends Output>(
    String route,
    Command<I, O> Function(CliRequest req) commandFactory, {
    required bool globals,
    required CliContract contract,
    String? description,
  }) {
    _builderFor('', _root).command<I, O>(
      route,
      commandFactory,
      globals: globals,
      description: description,
      contract: contract,
    );
    return this;
  }

  /// Registers [pattern] as a route that dispatches to the same handler
  /// already registered for [target] (the full name of a route already
  /// registered via [query], [command] or [ModuleBuilder], e.g. `'eval
  /// rpn'`), but under [pattern]'s own, independently declared [contract]
  /// and [globals] scope (issue #27 section 4: "a declared route that runs
  /// the target's handler with a narrower contract").
  ///
  /// This is for a route that means the same thing as a longer one but is
  /// spelled differently and more narrowly:
  /// `cli.shortcut('&lt;program&gt;', target: 'eval rpn', globals: false,
  /// contract: CliContract.none)` lets a bare program argument alone run
  /// exactly what
  /// `eval rpn --program &lt;program&gt;` would, without exposing
  /// `eval rpn`'s other options (`--file`, `--stdin`) or accepting global
  /// options at all when `globals: false` (`cli_router.cmd` itself refuses
  /// a global option on a route declared `globals: false`, so nothing
  /// further has to be done here to enforce that).
  ///
  /// [contract]'s positionals are validated against [pattern] exactly as an
  /// ordinary [query]/[command] registration's are (missing, extra,
  /// misnamed, duplicate or wrongly required/optional is an [ArgumentError]
  /// at registration).
  ///
  /// A shortcut is deliberately **not** given its own [CommandCatalog]
  /// entry: it is another way to spell an existing command, not a second
  /// command, and it would otherwise show up in `help` as if it needed its
  /// own explanation when the one at [target] already is that explanation.
  /// One consequence: on a rejected invocation of a shortcut (one that
  /// never resolves, so no route handler ever runs), the focused help
  /// `--help` and a JSON error's `contract` field would otherwise fall
  /// back to is looked up from [CommandCatalog] alone, which a shortcut is
  /// never in, so neither is available there by default; a caller is
  /// directed to [target]'s own help instead (round-5 review finding 3).
  /// This default still holds whenever resolution itself cannot settle on
  /// this one shortcut: no route information reaches it at all, or more
  /// than one candidate remains genuinely ambiguous. When resolution does
  /// settle on exactly this shortcut, though (round-9 review finding 4),
  /// `--help` answers with its own contract after all, the same as a
  /// *resolved* shortcut invocation's own `--help` already does, like any
  /// other resolved route, with its own contract, options and all; nothing
  /// in issue #27 says otherwise.
  ///
  /// [contract] declares only options and constraints: a shortcut's
  /// positionals are taken from [target]'s own positional declarations,
  /// matched by name, and bound to whichever cardinality [pattern] itself
  /// gives them. Required, like every other registration call on this SDK
  /// ([CliContract.none] for a shortcut that declares nothing itself): when
  /// [target] is a [Command], [contract] gains [ChangeFlags.params]
  /// regardless, the same way [command] itself always gains them. See
  /// [ModuleBuilder.shortcut] for the full account, including issue #27's
  /// own example.
  ///
  /// Throws [ArgumentError] if [target] names no registered route, more
  /// than one, or if [contract] declares a positional directly.
  ModularCli shortcut(
    String pattern, {
    required String target,
    required bool globals,
    required CliContract contract,
    String? description,
  }) {
    _builderFor('', _root).shortcut(
      pattern,
      target: target,
      globals: globals,
      contract: contract,
      description: description,
    );
    return this;
  }

  /// The registered route word closest to [word]: see
  /// [CommandCatalog.suggest]. Uses this CLI's own [_suggestionDistance]
  /// unless [maxDistance] overrides it for this one call.
  String? suggest(String word, {int? maxDistance}) =>
      _catalog.suggest(word, maxDistance: maxDistance ?? _suggestionDistance);

  ModuleBuilder _builderFor(String name, CliRouter router) => ModuleBuilder(
    moduleName: name,
    router: router,
    catalog: _catalog,
    bodiesByName: _bodiesByName,
    shortcutContractsByExactRoute: _shortcutContractsByExactRoute,
    shortcutContractsByPrefix: _shortcutContractsByPrefix,
    approver: _approver,
    planSink: _planSink,
  );

  /// Add a shelf-like middleware to the root router.
  ///
  /// Middlewares are applied in registration order and wrap all routes across
  /// all modules.
  ///
  /// A middleware that throws a [CommandException] is caught inside its own
  /// error boundary, exactly as before, but that boundary no longer renders
  /// anything itself: it only records the exception, into the current
  /// invocation's own [InvocationOutcome] (see [runWithInvocationOutcome],
  /// [recordInvocationError]), and swallows it into a plain returned exit
  /// code, so an outer middleware wrapping this one can still inspect that
  /// code through its own `await next(req)`, precisely as it could before
  /// this fix (round-5 review finding 2). Actually rendering happens
  /// exactly once, in [run], after the whole middleware chain (and
  /// whatever it wraps) has finished.
  ///
  /// The outcome is reached through a [Zone], not an instance field the
  /// way an earlier fix kept it (round-6 review findings 1 through 3): a
  /// plain instance field is shared by every invocation on this same
  /// [ModularCli], so a handler that itself calls [run] again (a
  /// recursive invocation, its own sinks and all) or two concurrent [run]
  /// calls on the same instance would step on each other's recorded
  /// error, and nothing about an instance field says "discard this,
  /// the invocation that recorded it went on to recover" versus "this is
  /// what actually terminated it". A zone value, freshly created by
  /// [runWithInvocationOutcome] once per [run] call, cannot leak into a
  /// sibling or a parent invocation's own zone, and is preserved
  /// automatically across every `await` inside [middleware]'s own handler,
  /// exactly where an instance field would have to be threaded through by
  /// hand.
  ///
  /// That boundary covers a throw from [middleware] itself while it builds
  /// its handler (the outer `(next) { ... }` body), not just one from the
  /// handler it returns: `middleware(next)` is called here on every
  /// dispatch, inside the same per-request `try`, precisely so a
  /// construction-time throw is caught the same way a handler-time one is.
  ///
  /// Nested middleware boundaries each catch in turn, innermost first: an
  /// inner middleware's exception is recorded, then converted to a plain
  /// exit code an outer middleware's own logic can inspect; if that outer
  /// middleware itself throws (as the outer half of round-5 finding 2's
  /// regression test does, escalating a nonzero result of its own), its
  /// own boundary catches that and overwrites the recorded outcome in
  /// turn. Because catching unwinds from innermost to outermost, whichever
  /// exception is recorded last is necessarily the one that actually
  /// terminates the invocation, an outer boundary's own throw if it has
  /// one, an inner one otherwise, so "last recorded wins" is exactly
  /// "the outermost thrown wins".
  ///
  /// Round-8 review finding 2: [middleware] is built around a guarded
  /// `next`, not [CliHandler] `next` itself, so every actual call it makes
  /// to `next(req)` (once, never, or more than once on a retry) runs
  /// inside its own fresh [InvocationOutcome] frame
  /// ([InvocationOutcome.pushFrame], [InvocationOutcome.popFrame]).
  ///
  /// Round-9 review finding 1: a single "baseline", captured once and
  /// restored on every silent attempt, cannot tell apart two things this
  /// middleware invocation can each record on its own timeline: what this
  /// middleware records directly (`own`, e.g. via `output.writeError`, at
  /// any point in its own code, before its first `next()` call, between two
  /// of them, or after its last one) and the outcome of its latest
  /// completed `next()` attempt (`downstream`, replaced by every new
  /// attempt and cleared by a silent one). A baseline captured lazily on
  /// the first `next()` call is blind to an `own` recording made *after*
  /// that point, so a later silent retry wrongly restores the pre-attempt-1
  /// baseline over it. The fix keeps `own` and `downstream` as two
  /// completely independent slots and renders whichever was recorded more
  /// recently, by [InvocationOutcome.recordedAt] (a sequence number bumped
  /// once per [recordInvocationError] call across the whole invocation,
  /// surviving [InvocationOutcome.popFrame] folds unchanged): a slot that
  /// has never recorded anything (sequence number 0) never outranks the
  /// other, no matter how long ago the other last changed.
  ///
  /// `captureOwn` runs right before every `next()` attempt and once more
  /// after the whole wrapped handler returns (or throws): each time, it
  /// checks whether [InvocationOutcome.recordedAt] has moved since the last
  /// time this middleware looked, which can only mean this middleware's own
  /// code recorded something directly (a nested `next()` attempt's own
  /// recording is always already accounted for by `applyWinner`, below,
  /// immediately after that attempt completes, which also advances the
  /// sequence number this middleware has "seen").
  ///
  /// `applyWinner` writes the more recent of the two slots back into the
  /// outcome (and its own [InvocationOutcome.recordedAt], so an enclosing
  /// middleware's own comparison stays correct), or clears it to nothing
  /// when neither slot has ever recorded anything, but only once this
  /// middleware has actually engaged with `next()` at least once or
  /// recorded an `own` error itself: a middleware that never calls `next()`
  /// and never records anything of its own leaves whatever was already in
  /// the outcome (from before this middleware ran) completely untouched.
  ///
  /// Round-9 review finding 2: calling `next()` again while a previous
  /// `next()` call from this same middleware invocation has not yet
  /// completed is a programming error, not a retry: it corrupts the shared
  /// frame stack, since the two overlapping attempts would push and pop
  /// against each other rather than each other's own isolated frame. This
  /// throws a [StateError] naming the route, synchronously, before doing
  /// anything else, rather than attempting to merge the two. Frames stay
  /// isolated across separate, unrelated [run] calls exactly as before:
  /// `inFlight` is a fresh local variable for every dispatch of this
  /// middleware, one per request, reached only through this one closure.
  ModularCli use(CliMiddleware middleware) {
    _root.use((next) {
      return (req) async {
        final outcome = currentInvocationOutcome();

        CommandException? ownError;
        var ownJsonMode = false;
        String? ownExtraText;
        Map<String, dynamic>? ownExtraJson;
        var ownSeq = 0;

        CommandException? downError;
        var downJsonMode = false;
        String? downExtraText;
        Map<String, dynamic>? downExtraJson;
        var downSeq = 0;

        var lastSeenSeq = outcome.recordedAt;
        var everCalledNext = false;
        var inFlight = false;

        void captureOwn() {
          final seq = outcome.recordedAt;
          if (seq != 0 && seq != lastSeenSeq) {
            ownError = outcome.error;
            ownJsonMode = outcome.jsonMode;
            ownExtraText = outcome.extraText;
            ownExtraJson = outcome.extraJson;
            ownSeq = seq;
          }
          lastSeenSeq = seq;
        }

        void applyWinner() {
          if (ownSeq == 0 && downSeq == 0 && !everCalledNext) return;
          final useOwn = downSeq == 0 || (ownSeq != 0 && ownSeq > downSeq);
          if (useOwn) {
            outcome.error = ownError;
            outcome.jsonMode = ownJsonMode;
            outcome.extraText = ownExtraText;
            outcome.extraJson = ownExtraJson;
            outcome.recordedAt = ownSeq;
          } else {
            outcome.error = downError;
            outcome.jsonMode = downJsonMode;
            outcome.extraText = downExtraText;
            outcome.extraJson = downExtraJson;
            outcome.recordedAt = downSeq;
          }
        }

        Future<int> guardedNext(CliRequest guardedReq) async {
          if (inFlight) {
            throw StateError(
              "next() was called again for route '${req.route.pattern}' "
              "before this middleware's previous next() call for the same "
              'route had completed: overlapping next() calls from the same '
              'middleware invocation are not supported, retry them one '
              'after another instead.',
            );
          }
          inFlight = true;
          everCalledNext = true;
          captureOwn();
          outcome.pushFrame();
          try {
            return await next(guardedReq);
          } finally {
            if (outcome.popFrame()) {
              downError = outcome.error;
              downJsonMode = outcome.jsonMode;
              downExtraText = outcome.extraText;
              downExtraJson = outcome.extraJson;
              downSeq = outcome.recordedAt;
            } else {
              downError = null;
              downJsonMode = false;
              downExtraText = null;
              downExtraJson = null;
              downSeq = 0;
            }
            lastSeenSeq = downSeq;
            applyWinner();
            inFlight = false;
          }
        }

        try {
          final wrapped = middleware(guardedNext);
          final result = await wrapped(req);
          captureOwn();
          applyWinner();
          return result;
        } on CommandException catch (e) {
          recordInvocationError(e, jsonMode: req.flagBool('json'));
          captureOwn();
          applyWinner();
          return e.exitCode;
        }
      };
    });
    return this;
  }

  /// Dispatch [args] through the router and return an exit code.
  ///
  /// Pass custom [stdout] / [stderr] sinks for testing.
  ///
  /// The whole dispatch runs inside a fresh [InvocationOutcome], reachable
  /// only through the [Zone] [runWithInvocationOutcome] establishes for
  /// this one call (round-6 review findings 1 through 3): no SDK path
  /// writes an error to stderr directly any more (a handler's thrown
  /// [CommandException], an approval refusal, a failed step, a
  /// [use] middleware boundary, and a rejection this SDK classifies before
  /// any handler runs all call [recordInvocationError] instead), so
  /// exactly one write ever happens for the [CommandException] path,
  /// decided right here: once the whole chain returns, an exit code of 0
  /// discards whatever was recorded and renders nothing at all, even if an
  /// inner failure was recorded along the way and later recovered from or
  /// retried into success; a nonzero exit code renders whichever error was
  /// recorded last (see [use]'s own doc comment for why "last recorded" is
  /// exactly "outermost thrown"), exactly once, in the mode ([--json] or
  /// text) the request that recorded it was running under.
  Future<int> run(List<String> args, {io.IOSink? stdout, io.IOSink? stderr}) {
    return runWithInvocationOutcome(() async {
      _registerHelpCommand();
      final out = stdout ?? io.stdout;
      final err = stderr ?? io.stderr;

      // A bare invocation is a help request only when nothing else claims
      // it: a CLI may register its own root route (a dashboard, a status
      // screen), and bare `<cli>` is then that route, not a request for
      // help.
      if (args.isEmpty && _catalog.forRoute('') == null) {
        out.writeln(HelpRenderer(_catalog).renderCatalog());
        return ExitCode.ok;
      }

      final exitCode = await _root.run(
        args,
        onReject: (rejection) => _handleRejection(rejection, out),
        stdout: out,
        stderr: err,
      );

      if (exitCode != ExitCode.ok) {
        final outcome = currentInvocationOutcome();
        if (outcome.error != null) {
          // Round-8 review finding 1: the process exit code this call is
          // about to return is authoritative, not the recorded error's own
          // exitCode. A middleware may legitimately remap a handler's
          // result (a notFound turned into a genericError further up the
          // chain, say) after recording that handler's own CommandException
          // via next()'s nonzero return; the two exit codes then differ by
          // design, not by bug, so this must render, never reject the
          // mismatch. _renderRecordedError keeps the recorded id, message
          // and extras, but stamps the envelope's own exitCode field with
          // exitCode, the one actually being returned.
          _renderRecordedError(outcome, err, exitCode);
        }
      }
      return exitCode;
    });
  }

  /// Help must be reachable out of the box, unless the developer wrote their
  /// own `help`, in which case theirs is the CLI's help, everywhere.
  ///
  /// It is a query: it reads the catalog and answers. Registered with a
  /// trailing wildcard so a focus (`help math add`) is collected as [rest]
  /// rather than having to be a declared positional.
  void _registerHelpCommand() {
    if (_catalog.forName('help') != null) return;

    query<HelpInput, HelpOutput>(
      'help *',
      (req) => HelpQuery(HelpInput(_catalog, focus: req.rest)),
      globals: true,
      contract: CliContract.none,
      description: 'Show the commands this CLI accepts',
    );
  }

  // ── Help precedence on a rejected invocation ──────────────────────────────
  //
  // `cli_router.resolve()` classifies exactly what went wrong; it never says
  // whether `--help` should win over that. That precedence is this SDK's own
  // decision (issue #27):
  //
  //   * `--help` only wins for the rejection kinds that mean "this invocation
  //     trails off partway through a real route": [CliRejectionKind.incomplete],
  //     [CliRejectionKind.missingArgument] and
  //     [CliRejectionKind.missingRequiredOption]. These are exactly the cases
  //     where what the user is missing is the information `--help` would have
  //     given them anyway.
  //   * It never wins for a genuine shape error: an unknown command, an extra
  //     argument, an unknown/misplaced/malformed option, a repeated one. Those
  //     are told about what is actually wrong; `--help` having been typed
  //     alongside a typo does not make the typo not worth mentioning.
  //
  // Read straight off left-to-right parsing: whichever failure is hit first
  // decides both the [CliRejectionKind] and which options (`--help` among
  // them) had already been read when it was hit.

  static const _helpWinsKinds = {
    CliRejectionKind.incomplete,
    CliRejectionKind.missingArgument,
    CliRejectionKind.missingRequiredOption,
  };

  /// Kinds that mean the invocation's *shape* was wrong (command words or
  /// argument count) as opposed to a problem with one specific option.
  /// Mapped to [ExitCode.invalidUsage] (64); everything else, an option the
  /// user got wrong, is mapped to [ExitCode.validationFailed] (7), the
  /// mapping this SDK used before `cli_router` classified rejections itself,
  /// preserved deliberately rather than adopting 64 across the board.
  static const _structuralKinds = {
    CliRejectionKind.unknownCommand,
    CliRejectionKind.extraArgument,
    CliRejectionKind.incomplete,
    CliRejectionKind.missingArgument,
  };

  int _exitCodeFor(CliRejectionKind kind) => _structuralKinds.contains(kind)
      ? ExitCode.invalidUsage
      : ExitCode.validationFailed;

  /// Machine-readable counterpart of [_exitCodeFor]: one kebab-case `id` per
  /// [CliRejectionKind], the fixed table this SDK's README documents. Every
  /// error this SDK writes in JSON mode, whichever path produced it
  /// (`cli_router`'s own rejection or a handler's [CommandException]), uses
  /// the same kebab-case `id` vocabulary, so a caller parsing `--json`
  /// output never has to tell the two sources apart.
  String _errorIdFor(CliRejectionKind kind) => switch (kind) {
    CliRejectionKind.unknownCommand => 'unknown-command',
    CliRejectionKind.incomplete => 'incomplete-command',
    CliRejectionKind.missingArgument => 'missing-argument',
    CliRejectionKind.extraArgument => 'extra-argument',
    CliRejectionKind.unknownOption => 'unknown-option',
    CliRejectionKind.misplacedOption => 'misplaced-option',
    CliRejectionKind.missingRequiredOption => 'missing-required-option',
    CliRejectionKind.repeatedOption => 'repeated-option',
    CliRejectionKind.invalidShortOption => 'invalid-short-option',
    CliRejectionKind.missingValue => 'missing-value',
    CliRejectionKind.unexpectedValue => 'unexpected-value',
  };

  /// The one piece of structured detail this SDK can name without guessing:
  /// which declared parameter a [CliRejectionKind.missingRequiredOption]
  /// rejection is about. `null` for every other kind, and for a
  /// `missingRequiredOption` this SDK cannot resolve back to a contract.
  Map<String, dynamic>? _detailsFor(
    CliRejection rejection,
    CommandContract? contract,
  ) {
    if (rejection.kind != CliRejectionKind.missingRequiredOption) return null;
    if (contract == null) return null;
    final given = rejection.options.map((o) => o.spec.name).toSet();
    for (final option in contract.options) {
      if (option.required && !given.contains(option.name)) {
        return {'parameter': option.name};
      }
    }
    return null;
  }

  /// Resolves a rejection cli_router could not dispatch itself. Neither
  /// branch below writes anything: each only records, into the current
  /// invocation's own [InvocationOutcome], what [run] alone renders, once,
  /// after the whole dispatch finishes (round-6 review findings 1
  /// through 3).
  int _handleRejection(CliRejection rejection, io.IOSink out) {
    final helpRequested = rejection.options.any((o) => o.spec.name == 'help');
    final jsonMode = rejection.options.any((o) => o.spec.name == 'json');

    if (helpRequested && _helpWinsKinds.contains(rejection.kind)) {
      // A value the caller actually supplied is checked before letting
      // --help win, exactly as ModuleBuilder checks it before answering
      // --help on a resolved invocation (issue #27 section 5: "help loses
      // to an option error"). A missing required option or an unmet
      // constraint stay correctly skipped here: cli_router already
      // refused to resolve on the first, and the second is never checked
      // outside applyDeclaredContract. A badly typed supplied value
      // (`math add --a bad --help`, with --b also missing) is the one
      // failure `cli_router` cannot see for itself, and it must not lose
      // to --help just because the rejection that surfaced it happens to
      // be one help otherwise wins.
      //
      // A shortcut route has no catalog entry (by design: see [shortcut]'s
      // doc comment), so _contractFor() alone cannot see it, and this
      // check would otherwise be silently skipped for one.
      // _applicableContractFor() considers a shortcut's own contract here,
      // and, since round-9 review finding 4, this same resolved contract is
      // what _emitFocusedHelp() below actually renders: once resolution has
      // picked exactly one candidate (a shortcut among them, possibly), its
      // own help is the honest answer to "what does --help mean here",
      // superseding round-4 review finding 1's older rule of never showing
      // a shortcut's own contract, which only ever applied to the still
      // genuinely ambiguous or unresolved cases (round-6 review finding 6),
      // never to a case resolution has already disambiguated.
      //
      // Several shortcuts can share the literal prefix a rejection reports
      // (round-6 review finding 4): when they do, there is no one contract
      // to validate against or to fall back to, so --help must not win
      // silently on a guess (round-6 review finding 6). Falling through to
      // the plain rejection error, exactly as if --help had not been
      // passed, reports the router's own rejection instead of pretending
      // one candidate is the answer.
      final resolved = _applicableContractFor(rejection);
      if (resolved.ambiguous) {
        return _emitRejectionError(rejection, jsonMode: jsonMode);
      }
      final contract = resolved.contract;
      if (contract != null) {
        try {
          validateSuppliedOptionValues(rejection.options, contract.contract);
        } on CommandException catch (e) {
          recordInvocationError(e, jsonMode: jsonMode);
          return e.exitCode;
        }
      }
      return _emitFocusedHelp(
        rejection,
        out,
        jsonMode: jsonMode,
        resolvedContract: contract,
      );
    }
    return _emitRejectionError(rejection, jsonMode: jsonMode);
  }

  /// Help for a rejection `--help` won: [resolvedContract], when
  /// non-null, is what [_handleRejection] already resolved through
  /// [_applicableContractFor] (a shortcut's own contract, possibly, once
  /// round-9 review finding 4 disambiguated it down to exactly one
  /// candidate), and is rendered as-is, no further lookup needed. Only
  /// when it is null (nothing resolved, or [CliRejection.route] itself was
  /// null with the rejection kind not even reaching resolution) does this
  /// fall back to the most specific thing the router could still identify
  /// on its own (the command itself, then the module it belongs to), then,
  /// when neither is known, the full catalog (narrowed to completions of
  /// what was typed, exactly as the plain error path does).
  int _emitFocusedHelp(
    CliRejection rejection,
    io.IOSink out, {
    required bool jsonMode,
    CommandContract? resolvedContract,
  }) {
    final contract = resolvedContract ?? _contractFor(rejection);
    if (contract != null) {
      _writeHelp(
        out,
        jsonMode: jsonMode,
        json: contract.toJson(),
        text: HelpRenderer(_catalog).renderCommand(contract),
      );
      return ExitCode.ok;
    }

    final module = rejection.consumed.isEmpty ? '' : rejection.consumed.first;
    final moduleContracts = module.isEmpty
        ? const <CommandContract>[]
        : _catalog.forModule(module);
    if (moduleContracts.isNotEmpty) {
      _writeHelp(
        out,
        jsonMode: jsonMode,
        json: {
          'module': module,
          'commands': [for (final c in moduleContracts) c.toJson()],
        },
        text: HelpRenderer(_catalog).renderModule(module),
      );
      return ExitCode.ok;
    }

    final attempted = rejection.consumed.join(' ');
    final completions = _completionsOf(attempted);
    final scoped = completions.isEmpty ? _catalog : _narrowedTo(completions);
    _writeHelp(
      out,
      jsonMode: jsonMode,
      json: {
        'commands': [for (final c in scoped.commands) c.toJson()],
      },
      text: HelpRenderer(scoped).renderCatalog(),
    );
    return ExitCode.ok;
  }

  void _writeHelp(
    io.IOSink sink, {
    required bool jsonMode,
    required Map<String, dynamic> json,
    required String text,
  }) {
    sink.writeln(jsonMode ? jsonEncode(json) : text);
  }

  /// A rejection `--help` did not win: the failure itself, on stderr, with
  /// the same "here is the contract you were one flag away from honouring"
  /// context a rejected [CommandException] gets from [ModuleBuilder].
  ///
  /// It tells apart two things that are not the same. An invocation naming
  /// the **beginning of a registered route** is not unknown: what it lacks
  /// is the end. `math` where `math add` exists, or `api graphql` where
  /// `api graphql compile` does, are both that: a prefix with no ending,
  /// and the catalog knows it. Calling both cases "unknown command" sent the
  /// user looking for a typo they had not made, and answered with the whole
  /// catalog when a handful of lines were the relevant ones.
  ///
  /// Neither writes anything itself: it only records, into the current
  /// invocation's own [InvocationOutcome], what [run] alone renders, once,
  /// after the whole dispatch finishes (round-6 review findings 1
  /// through 3). The `contract` field a JSON envelope carries alongside a
  /// [CommandException]'s own `id`/`message`/`exitCode`/`details` is not
  /// part of [CommandException.toJson()] itself, so it travels separately,
  /// through [recordInvocationExtraJson]; the same "you were one flag away"
  /// help text a text-mode envelope carries travels through
  /// [recordInvocationExtraText].
  int _emitRejectionError(CliRejection rejection, {required bool jsonMode}) {
    final exitCode = _exitCodeFor(rejection.kind);
    final contract = _contractFor(rejection);
    final attempted = rejection.consumed.join(' ');
    final completions = contract == null
        ? _completionsOf(attempted)
        : const <CommandContract>[];

    // The router tells apart eleven ways an invocation can fail, but not
    // whether the one it hit means "you named the beginning of a real
    // route and stopped". This SDK does, from the same catalog help is
    // rendered from: no contract names this exact invocation, yet at least
    // one registered route continues it. That is not the generic
    // "incomplete command" / "'x' does not continue this command" the
    // router itself would say: it is a specific, answerable thing.
    //
    // This rewrite applies to [CliRejectionKind.incomplete] alone: it is
    // the one kind that means "trails off partway through a real route",
    // which is exactly what "is not a complete command" describes. Every
    // other kind (`eval --json --bogus` is `unknownOption`, not
    // `incomplete`) keeps the router's own message untouched: nothing
    // here rewrites a message keyed on anything but the kind.
    final routerMessage = rejection.message ?? rejection.kind.name;
    final message = _withSuggestion(
      rejection.kind,
      rejection.token,
      rejection.kind == CliRejectionKind.incomplete &&
              contract == null &&
              completions.isNotEmpty
          ? "'$attempted' is not a complete command"
          : routerMessage,
    );

    final details = _detailsFor(rejection, contract);
    recordInvocationError(
      CommandException(
        id: _errorIdFor(rejection.kind),
        message: message,
        exitCode: exitCode,
        details: details,
      ),
      jsonMode: jsonMode,
    );
    if (jsonMode) {
      if (contract != null) {
        recordInvocationExtraJson({'contract': contract.toJson()});
      }
    } else {
      recordInvocationExtraText(
        contract != null
            ? HelpRenderer(_catalog).renderCommand(contract)
            : HelpRenderer(
                completions.isEmpty ? _catalog : _narrowedTo(completions),
              ).renderCatalog(),
      );
    }
    return exitCode;
  }

  /// Renders [outcome]'s recorded error to [err], exactly once: the only
  /// place, in the whole SDK, that ever writes a [CommandException] out
  /// (round-6 review findings 1 through 3). Called by [run], and only when
  /// the invocation's final exit code is nonzero and an error was actually
  /// recorded, never on a recovered or retried-into-success invocation.
  ///
  /// [processExitCode] overrides the rendered envelope's own `exitCode`
  /// field (round-8 review finding 1): the recorded error's own `exitCode`
  /// may differ from it when a middleware legitimately remaps the final
  /// result after recording it, and what is shown must match what the
  /// process actually returns, not a superseded intermediate value. `id`,
  /// `message`, `details` and any extras stay exactly as recorded.
  void _renderRecordedError(
    InvocationOutcome outcome,
    io.IOSink err,
    int processExitCode,
  ) {
    final error = outcome.error!;
    if (outcome.jsonMode) {
      final json = {
        ...error.toJson(),
        ...?outcome.extraJson,
        'exitCode': processExitCode,
      };
      err.writeln(jsonEncode({'error': json}));
      return;
    }
    err.writeln('Error: ${error.message} [${error.id}]');
    if (error.details != null && error.details!.isNotEmpty) {
      for (final entry in error.details!.entries) {
        err.writeln('  ${entry.key}: ${entry.value}');
      }
    }
    if (outcome.extraText != null) {
      err
        ..writeln()
        ..writeln(outcome.extraText);
    }
  }

  /// Appends a "did you mean" suggestion to [finalMessage] when [kind] is
  /// one naming an offending word ([CliRejectionKind.unknownCommand] or
  /// [CliRejectionKind.incomplete]) and [CommandCatalog.suggest] finds a
  /// close enough registered word for it.
  ///
  /// The word is read from [token] ([CliRejection.token]), typed instead of
  /// parsed out of the router's message: the router's message is prose for
  /// logging, its wording can change, and an offending token containing a
  /// quote character would make a regex over the message extract a
  /// truncated, wrong word. [token] is never read from [finalMessage]
  /// either, since that may already have been rewritten (the "is not a
  /// complete command" case above) into text that does not name the
  /// offending word at all. Gated on [kind] alone, exactly like the
  /// rewrite above: it is an addition, not a substitution, so it cannot
  /// change what the router itself reported, only add a suggestion after
  /// it.
  String _withSuggestion(
    CliRejectionKind kind,
    String? token,
    String finalMessage,
  ) {
    if (kind != CliRejectionKind.unknownCommand &&
        kind != CliRejectionKind.incomplete) {
      return finalMessage;
    }
    if (token == null || token.isEmpty) return finalMessage;
    final suggestion = _catalog.suggest(
      token,
      maxDistance: _suggestionDistance,
    );
    if (suggestion == null) return finalMessage;
    return "$finalMessage. Did you mean '$suggestion'?";
  }

  /// The contract a rejection points at: the route `cli_router` itself named
  /// ([CliRejection.route], set for [CliRejectionKind.missingRequiredOption]
  /// among others), or, failing that, the route named by the words already
  /// consumed: the case `cli_router` could not yet identify a specific
  /// route for ([CliRejectionKind.incomplete], [CliRejectionKind.missingArgument]).
  CommandContract? _contractFor(CliRejection rejection) {
    final route = rejection.route;
    if (route != null) return _catalog.forRoute(route.pattern);
    if (rejection.consumed.isEmpty) return null;
    return _catalog.forName(rejection.consumed.join(' '));
  }

  /// The contract a rejection's own literal-words prefix should actually be
  /// validated and consulted against, when both an ordinary catalog route
  /// and a shortcut can answer to that same prefix at different positional
  /// depths (round-7 review finding 2).
  ///
  /// [_contractFor] and the shortcut lookup's own literal-words fallback
  /// each match [CliRejection.consumed] on name alone, with no notion of how
  /// much further the invocation itself is still trying to go: an ordinary
  /// route `s`, no positionals, and a shortcut `s <id> <sub>` both answer to
  /// the very same consumed prefix `['s']`. Before this method existed,
  /// `_contractFor(rejection) ?? shortcutLookup.contract` picked the
  /// catalog's own match unconditionally whenever one existed, so the
  /// shallower, unrelated route's contract silently overrode the deeper
  /// shortcut the invocation was actually reaching for.
  ///
  /// The fix relies on actual routing progress, never a candidate's static
  /// total arity (round-8 review finding 3: comparing total positional
  /// counts picked a winner even when the router had not actually
  /// progressed past either candidate, e.g. both still reaching for the
  /// very same first positional). `cli_router`'s own trie enforces one name
  /// per shared positional slot: two routes continuing the same slot under
  /// different names is a build-time [ArgumentError] (see `_Trie.register`
  /// in `cli_router`), so [CliRejectionKind.missingArgument]'s
  /// [CliRejection.argument] names the exact slot the invocation is still
  /// stuck on, typed, straight from the router. A candidate that does not
  /// declare a positional under
  /// that name has already fallen out of the running by definition; a
  /// candidate that does is still viable. Exactly one still-viable
  /// candidate resolves unambiguously; zero or more than one (including
  /// both candidates still reaching for the same slot) is genuinely
  /// ambiguous, and this reports that the same way the old shortcut lookup's
  /// own ambiguous case already did (round-6 review finding 6): the
  /// router's own rejection, rather than guessing.
  ///
  /// [CliRejectionKind.incomplete] carries no such positional name
  /// ([CliRejection.argument] is always null for it: the router itself has
  /// nothing pending at that node), so there is no routing-progress signal
  /// to resolve from; this is treated the same as any other null
  /// [CliRejection.argument], ambiguous.
  ///
  /// [CliRejection.route] being non-null names one exact route `cli_router`
  /// itself resolved to: unambiguous by construction (a second registration
  /// under the same exact pattern is a build-time error, round-6 review
  /// finding 4), so none of this applies there.
  ///
  /// Round-9 review findings 3 and 4: when [CliRejection.route] is null,
  /// this no longer asks [_contractFor] and the old shortcut-only lookup for
  /// one answer each and compares those two. [_contractFor] looks up the
  /// catalog by name and, like [CommandCatalog.forName], returns only the
  /// first entry it finds, even when two distinct registered routes share
  /// the exact same words-only name (`s` and `s <id> <sub>` are both named
  /// `s`): the other one, possibly the only one still viable at the missing
  /// positional, was never even considered. The old shortcut-only lookup had
  /// the opposite problem: it declared more than one shortcut sharing a
  /// prefix ambiguous immediately, before ever checking whether only one of
  /// them still declares the missing positional.
  ///
  /// The fix collects every candidate first, every catalog entry sharing
  /// the consumed words as its name ([CommandCatalog.allForName], not
  /// [CommandCatalog.forName]) and every shortcut sharing the same literal
  /// prefix, into one list, and only then decides: zero candidates is
  /// nothing to answer with; exactly one is the unambiguous answer; more
  /// than one is filtered by [CliRejection.argument], the exact positional
  /// name the router itself is still stuck on
  /// ([_declaresPositional]): a candidate that does not declare it has
  /// already fallen out of the running. Exactly one survivor after that
  /// filter resolves; zero or more than one (including no
  /// [CliRejection.argument] to filter by at all, [CliRejectionKind.incomplete]'s
  /// case) is genuinely ambiguous, reported the same way the old
  /// shortcut-only lookup's own ambiguous case already was.
  ({CommandContract? contract, bool ambiguous}) _applicableContractFor(
    CliRejection rejection,
  ) {
    final route = rejection.route;
    if (route != null) {
      final catalogContract = _catalog.forRoute(route.pattern);
      final shortcutContract = _shortcutContractsByExactRoute[route.pattern];
      return (contract: catalogContract ?? shortcutContract, ambiguous: false);
    }

    final consumedKey = rejection.consumed.join(' ');
    final candidates = <CommandContract>[
      if (rejection.consumed.isNotEmpty) ..._catalog.allForName(consumedKey),
      ...?_shortcutContractsByPrefix[consumedKey],
    ];

    if (candidates.isEmpty) return (contract: null, ambiguous: false);
    if (candidates.length == 1) {
      return (contract: candidates.single, ambiguous: false);
    }

    final missingName = rejection.argument;
    if (missingName == null) return (contract: null, ambiguous: true);

    final viable = candidates
        .where((c) => _declaresPositional(c, missingName))
        .toList();
    if (viable.length == 1) return (contract: viable.single, ambiguous: false);
    return (contract: null, ambiguous: true);
  }

  bool _declaresPositional(CommandContract contract, String name) =>
      contract.positionals.any((p) => p.name == name);

  /// Every registered route that continues [attempted].
  ///
  /// Matched on the route **without positional placeholders**, so `records`
  /// finds `records show <id>`; and with a trailing space, so a prefix has to
  /// end on a segment boundary — `mat` does not complete into `math add`.
  List<CommandContract> _completionsOf(String attempted) {
    if (attempted.isEmpty) return const [];
    return _catalog.commands
        .where((contract) => contract.name.startsWith('$attempted '))
        .toList();
  }

  CommandCatalog _narrowedTo(List<CommandContract> contracts) {
    final narrowed = CommandCatalog();
    for (final contract in contracts) {
      narrowed.register(contract);
    }
    return narrowed;
  }

  /// Print the help listing for all registered modules and routes.
  void printHelp(io.IOSink sink, {String? title}) {
    if (title != null) {
      sink
        ..writeln(title)
        ..writeln();
    }
    sink.writeln(HelpRenderer(_catalog).renderCatalog());
  }
}
