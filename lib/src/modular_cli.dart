import 'dart:convert';
import 'dart:io' as io;

import 'package:cli_router/cli_router.dart';

import 'approver.dart';
import 'cli_contract.dart';
import 'cli_plugin.dart';
import 'cli_plugin_host.dart';
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
  ///
  /// [name] and [version] identify this CLI to a plugin that asks
  /// [CliPluginHost.metadata]: a plugin that ships a `version` route or
  /// compares an installed version against a release has to be told both.
  /// Left null, [hostMetadata] is null and such a plugin's [setup] throws
  /// rather than reporting a name or version nobody gave it.
  ModularCli({
    Approver? approver,
    PlanSink? planSink,
    required int suggestionDistance,
    String? name,
    String? version,
  }) : _approver = approver,
       _planSink = planSink,
       _suggestionDistance = suggestionDistance,
       hostMetadata = name == null && version == null
           ? null
           : CliHostMetadata(
               name: _requireBoth(name, version, 'name'),
               version: _requireBoth(version, name, 'version'),
             );

  final Approver? _approver;
  final PlanSink? _planSink;
  final int _suggestionDistance;

  /// This CLI's own name and version, as given to the constructor: the one
  /// piece of information a plugin cannot declare about itself. Null unless
  /// both [name] and [version] were given.
  final CliHostMetadata? hostMetadata;

  static String _requireBoth(String? value, String? other, String label) {
    if (value == null) {
      throw ArgumentError(
        'ModularCli was given ${other == null ? 'neither' : 'only'} name/'
        'version: give both or neither; a $label with no counterpart is not '
        'a CLI identity a plugin can rely on.',
      );
    }
    return value;
  }

  late final CliRouter _root = CliRouter(globalOptions: globalOptionSpecs);
  final CommandCatalog _catalog = CommandCatalog();
  final List<CliPlugin> _plugins = [];
  bool _pluginsBuilt = false;
  Object? _buildFailure;
  StackTrace? _buildFailureStack;

  /// Every registered route's business logic, keyed by
  /// [CommandContract.route]. Shared by every [ModuleBuilder] this instance
  /// builds, so [shortcut] can find a target route's logic no matter which
  /// module registered it, and dispatch it under the shortcut's own
  /// contract. See [ContractAwareBody].
  final Map<String, ContractAwareBody> _bodiesByName = {};

  /// Every shortcut's own contract, keyed by `cli_router`'s own
  /// `route.pattern` identity: mount prefix included, a trailing optional
  /// positional or wildcard stripped, a required one kept. A plain lookup
  /// by route pattern through [_catalog] alone cannot see a shortcut at
  /// all (a shortcut is deliberately not given its own catalog entry: see
  /// [shortcut]'s own doc comment), so [_handleRejection] consults this
  /// too, to check a
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

  /// Register a plugin. Chainable, like [module], [query] and [command].
  ///
  /// Registering does not run [CliPlugin.setup]: that is deferred to
  /// [buildPlugins], so every plugin can be added, in whatever order the host
  /// application finds natural, before any of them is validated or given a
  /// chance to register a route. [run] calls [buildPlugins] itself; call it
  /// directly only where you need the plugin set built without also
  /// dispatching an invocation, such as a test that asserts on [catalog].
  ///
  /// Throws [StateError] once [buildPlugins] has been attempted, whether it
  /// succeeded or failed: a plugin added after that point would silently
  /// never run (a success has already set up every plugin it knew about) or
  /// would be added to a set already found broken, neither of which this
  /// method accepts without saying so.
  ModularCli plugin(CliPlugin plugin) {
    if (_pluginsBuilt) {
      throw StateError(
        'Cannot register plugin "${plugin.manifest.id}": the plugin set was '
        'already built. Call plugin() for every plugin before run() or '
        'buildPlugins() runs.',
      );
    }
    _plugins.add(plugin);
    return this;
  }

  /// Validate and set up every plugin registered with [plugin].
  ///
  /// Idempotent on success: a second call, including the one [run] makes,
  /// does nothing. Validation happens for every plugin before
  /// [CliPlugin.setup] runs for any of them: a duplicate id, an incompatible
  /// [CliPluginManifest.hostApiVersion], a missing dependency or a dependency
  /// cycle is a failure of the whole set, not of whichever plugin happened to
  /// be set up first, so none of the set is allowed to register a single
  /// route before every plugin in it has passed every check that does not
  /// require running [setup] itself.
  ///
  /// Throws [CliPluginError]: there is no fallback that runs a plugin set
  /// found to be broken. A failed build is remembered, not merely marked
  /// done: a second call, including the one [run] makes on every invocation,
  /// rethrows the same failure instead of silently skipping validation and
  /// dispatching against whatever partial state the first attempt left.
  void buildPlugins() {
    if (_pluginsBuilt) {
      final failure = _buildFailure;
      if (failure != null) {
        Error.throwWithStackTrace(
          failure,
          _buildFailureStack ?? StackTrace.current,
        );
      }
      return;
    }
    if (_plugins.isEmpty) {
      _pluginsBuilt = true;
      return;
    }

    try {
      final ordered = orderCliPlugins(_plugins);
      for (final plugin in ordered) {
        checkHostApiCompatibility(plugin.manifest);
      }

      final host = RuntimeCliPluginHost(this);
      for (final plugin in ordered) {
        host.currentPluginId = plugin.manifest.id;
        plugin.setup(host);
      }
      _pluginsBuilt = true;
    } on Object catch (e, st) {
      _pluginsBuilt = true;
      _buildFailure = e;
      _buildFailureStack = st;
      rethrow;
    }
  }

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
  /// isolated from this middleware's own recordings.
  ///
  /// Round-9 review finding 1: a single "baseline", captured once and
  /// restored on every silent attempt, cannot tell apart two things this
  /// middleware invocation can each record on its own timeline: what this
  /// middleware records directly (`own`, e.g. via `output.writeError`, at
  /// any point in its own code, before its first `next()` call, between two
  /// of them, or after its last one) and the outcome of its latest
  /// completed `next()` attempt (`downstream`, replaced by every new
  /// attempt and cleared by a silent one). The fix keeps `own` and
  /// `downstream` as two completely independent slots and renders
  /// whichever was recorded more recently, by [InvocationOutcome.recordedAt]
  /// (a sequence number bumped once per [recordInvocationError] call across
  /// the whole invocation): a slot that has never recorded anything
  /// (sequence number 0) never outranks the other, no matter how long ago
  /// the other last changed.
  ///
  /// Round-10 review finding 1: round-9's own fix still told `own` and
  /// `downstream` apart through a shared, mutable "topmost frame" pointer,
  /// pushed the instant `next()` was called, synchronously, before its
  /// first `await`. A middleware that starts `pending = next(req)` without
  /// awaiting it yet, then records its own error in that same synchronous
  /// continuation, records into whatever the topmost frame already is at
  /// that instant, the freshly pushed downstream frame, not this
  /// middleware's own: a later silent retry then folds that frame away as
  /// "this attempt recorded nothing", discarding the earlier recording
  /// along with it. [InvocationOutcome.runAttempt] fixes this by binding
  /// each `next()` attempt to a [Zone] of its own instead of a shared stack
  /// position: every recording anywhere in this file resolves the frame it
  /// writes through [Zone.current], so code running in this middleware's
  /// own continuation always lands in its own slot, and code running inside
  /// a pending attempt always lands in that attempt's, regardless of which
  /// one the event loop happens to run first. `own` below needs no
  /// capturing at all any more: it is whatever is already in
  /// [InvocationOutcome], written straight there by every recording this
  /// middleware's own code makes, whenever it makes it. `latestAttempt`
  /// holds only the most recent completed attempt's own [RecordedOutcome]
  /// (`null` if it recorded nothing), overwritten whole by every new
  /// attempt rather than merged with an earlier one, so a superseded
  /// attempt cannot outlive the later, silent one that superseded it.
  /// `reconcile` compares the two exactly once, after the whole wrapped
  /// handler has settled, and copies `latestAttempt` over `own` only when
  /// it is the more recent of the two; comparing per attempt instead, as an
  /// earlier version of this fix did, would let an attempt's own recording
  /// linger in [InvocationOutcome] past a later attempt that superseded it
  /// by recording nothing, exactly the failure round-8 review finding 2's
  /// own retry fixture guards against.
  ///
  /// Round-9 review finding 2: calling `next()` again while a previous
  /// `next()` call from this same middleware invocation has not yet
  /// completed is a programming error, not a retry. Round-10's own fix
  /// removed the shared frame stack that finding used to warn this would
  /// corrupt, each attempt now gets its own isolated frame regardless, but
  /// two overlapping attempts sharing one middleware invocation's local
  /// state (this `inFlight` guard included) is still not a supported
  /// retry pattern, so this keeps throwing a [StateError] naming the
  /// route, synchronously, before doing anything else, rather than letting
  /// the two race. `inFlight` is a fresh local variable for every dispatch
  /// of this middleware, one per request, reached only through this one
  /// closure.
  ModularCli use(CliMiddleware middleware) {
    _root.use((next) {
      return (req) async {
        final outcome = currentInvocationOutcome();
        var inFlight = false;
        var everCalledNext = false;

        // Overwritten whole by every attempt, never merged with an earlier
        // one: a superseded attempt's own recording must not linger past a
        // later, silent one, exactly as round-8 review finding 2's own
        // fixture (a retry whose second attempt succeeds) still requires.
        // `own`, by contrast, never needs capturing here at all: it is
        // written straight into whatever is ambient by every call to
        // [recordInvocationError] that is not itself inside an attempt's
        // own zone, so it is already sitting in [outcome] by the time
        // [reconcile] runs, whatever its own timeline was relative to the
        // attempts below.
        RecordedOutcome? latestAttempt;

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
          try {
            return await outcome.runAttempt(
              () async => await next(guardedReq),
              onSettled: (recorded) => latestAttempt = recorded,
            );
          } finally {
            inFlight = false;
          }
        }

        // Compares `own` (whatever is already in [outcome], written there
        // directly by any recording this middleware's own code made) against
        // only the latest attempt's own recording, by [RecordedOutcome.recordedAt]:
        // whichever is more recent wins. Called once, after the whole
        // wrapped handler has settled, never per attempt, so an earlier
        // attempt superseded by a later, silent one can never win merely
        // for having been folded in first.
        void reconcile() {
          if (!everCalledNext) return;
          final attempt = latestAttempt;
          if (attempt != null && attempt.recordedAt > outcome.recordedAt) {
            outcome.error = attempt.error;
            outcome.jsonMode = attempt.jsonMode;
            outcome.extraText = attempt.extraText;
            outcome.extraJson = attempt.extraJson;
            outcome.recordedAt = attempt.recordedAt;
          }
        }

        try {
          final wrapped = middleware(guardedNext);
          final result = await wrapped(req);
          reconcile();
          return result;
        } on CommandException catch (e) {
          recordInvocationError(e, jsonMode: req.flagBool('json'));
          reconcile();
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
      // Plugins are built first, so a `help` a plugin registers counts as
      // the CLI's own when [_resolveHelpProvenance] classifies it below.
      buildPlugins();
      // Round-13 review findings 1 and 2: [_resolveHelpProvenance] is
      // memoized, resolved once no matter how many times [run] itself is
      // called. See its own doc comment for why re-deriving this per call,
      // straight off [_catalog], was wrong on both counts round 12 left in
      // place.
      final helpProvenance = _resolveHelpProvenance();
      final out = stdout ?? io.stdout;
      final err = stderr ?? io.stderr;

      // A bare invocation is a help request only when nothing else claims
      // it: a CLI may register its own root route (a dashboard, a status
      // screen), and bare `<cli>` is then that route, not a request for
      // help.
      //
      // Round-12 review finding 2: two things besides a root route already
      // answer a bare invocation on their own, and the old code, printing
      // the built-in catalog directly whenever no root *route* existed,
      // never gave either a chance to. A root *shortcut*
      // (`shortcut('', target: 'status', ...)`) dispatches through this
      // same router exactly as an ordinary route does (see
      // [ModuleBuilder.shortcut]), but, by design, has no [_catalog] entry
      // of its own, so [CommandCatalog.forRoute] alone can never see one:
      // a bare invocation on a CLI whose only root registration is a
      // shortcut still fell through to the catalog printer instead of
      // dispatching to the shortcut's own target. And a developer's own
      // `help` route, registered before this call ever runs, was bypassed
      // outright: the old code never dispatched through the router at all
      // when there was no root route, so the developer's own handler
      // never ran for a bare invocation, a regression against
      // `origin/main`'s own args-rewriting approach, which always let a
      // bare invocation flow through ordinary dispatch instead of
      // short-circuiting it.
      //
      // The fix is a real, three-way, declared order: a root route or
      // root shortcut, when either is registered, answers the bare
      // invocation exactly as any other invocation of it would (dispatch
      // continues below, `args` unchanged); otherwise a `help` command,
      // developer route or developer shortcut alike, registered before
      // this call ever ran (round-13: [_HelpProvenance.developerRoute] or
      // [_HelpProvenance.developerShortcut]) answers it instead (dispatch
      // continues below with `['help']`, the very same word the router
      // would resolve to for anyone typing it themselves); and only when
      // neither exists at all ([_HelpProvenance.builtin]) does this fall
      // back to printing the built-in catalog directly, exactly as
      // before.
      final hasRootRegistration =
          _catalog.forRoute('') != null ||
          _shortcutContractsByExactRoute.containsKey('');
      final dispatchArgs = args.isEmpty && !hasRootRegistration
          ? (helpProvenance == _HelpProvenance.builtin ? null : const ['help'])
          : args;

      if (dispatchArgs == null) {
        out.writeln(HelpRenderer(_catalog).renderCatalog());
        return ExitCode.ok;
      }

      final exitCode = await _root.run(
        dispatchArgs,
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

  /// Where this CLI's own `help` command comes from: a developer's own
  /// ordinary route, a developer's own shortcut, or the SDK's own
  /// built-in default. An enum, not a boolean inferred from the catalog
  /// (round-13 review findings 1 and 2): re-deriving "is `help` a
  /// developer's own" straight off [_catalog] on every [run] call cannot
  /// tell a developer's own route apart from the built-in default once
  /// that default has itself been registered into the very same catalog,
  /// and cannot see a developer's own shortcut at all, since a shortcut is
  /// deliberately never given a catalog entry (see
  /// [_shortcutContractsByExactRoute]'s own doc comment).
  _HelpProvenance? _helpProvenance;

  /// Resolves [_helpProvenance], registering the SDK's own built-in
  /// `help` command the first, and only, time neither a developer route
  /// nor a developer shortcut named `help` already exists. Memoized:
  /// every call after the first returns the very same value, however many
  /// times [run] itself is called and however many routes the built-in
  /// registration eventually adds to the catalog.
  ///
  /// Round-13 review finding 1: a shortcut named `help`
  /// (`shortcut('help', target: 'manual', ...)`) is mounted straight onto
  /// the router (see [ModuleBuilder.shortcut]), occupying the exact trie
  /// position the built-in `help *` registration below would also claim,
  /// but, by design, it is never given a [_catalog] entry, so the old
  /// catalog-only check (`_catalog.forName('help') != null`) could never
  /// see it: it registered the built-in default over it regardless, and
  /// the very first [run] call threw once the router refused the
  /// resulting conflicting registration. Checking
  /// [_shortcutContractsByExactRoute] too closes that gap.
  ///
  /// Round-13 review finding 2: the old check ran again on every [run]
  /// call, reading straight off [_catalog], which the built-in
  /// registration itself mutates the first time it runs; from the second
  /// [run] call on, the check found its own earlier registration and
  /// mistook it for a developer's own route, taking a different dispatch
  /// path (through the router, and whatever middleware sits in front of
  /// it) than the very first call did (straight to the built-in catalog
  /// printer, no middleware at all) for the exact same bare invocation on
  /// the exact same instance, silently flipping success into failure
  /// whenever a middleware in front of the router happened to fail.
  /// Resolving once, and caching what was resolved before either
  /// registration can influence a later check, keeps every call's answer
  /// identical.
  ///
  /// Round-14 review finding 2: checking [_shortcutContractsByExactRoute]
  /// by the exact key `help` (round-13's own fix) only ever caught a
  /// shortcut whose trailing positional is optional or a wildcard, both of
  /// which [ModuleBuilder.shortcut] strips from that map's own key; a
  /// shortcut with a *required* positional (`shortcut('help <topic>', ...)`)
  /// keeps it in the key (`help <topic>`), so the exact-key lookup missed
  /// it just as the pre-round-13 catalog-only check once did, registering
  /// the built-in default over it and throwing on the very first [run]
  /// call exactly as before. [_isNamedHelp] is the same predicate
  /// [CommandContract.name] already gives [CommandCatalog.forName] for an
  /// ordinary route (every positional placeholder stripped, required or
  /// not, wherever it falls), applied here to both [_catalog]'s own
  /// entries and every shortcut's [CommandContract], so a route and a
  /// shortcut named `help` are told apart from the built-in default by the
  /// exact same rule regardless of whether either declares a positional,
  /// and regardless of that positional's cardinality.
  ///
  /// It is a query: it reads the catalog and answers. Registered with a
  /// trailing wildcard so a focus (`help math add`) is collected as [rest]
  /// rather than having to be a declared positional.
  _HelpProvenance _resolveHelpProvenance() {
    final cached = _helpProvenance;
    if (cached != null) return cached;

    final _HelpProvenance resolved;
    if (_catalog.commands.any(_isNamedHelp)) {
      resolved = _HelpProvenance.developerRoute;
    } else if (_shortcutContractsByExactRoute.values.any(_isNamedHelp)) {
      resolved = _HelpProvenance.developerShortcut;
    } else {
      resolved = _HelpProvenance.builtin;
      query<HelpInput, HelpOutput>(
        'help *',
        (req) => HelpQuery(HelpInput(_catalog, focus: req.rest)),
        globals: true,
        contract: CliContract.none,
        description: 'Show the commands this CLI accepts',
      );
    }
    _helpProvenance = resolved;
    return resolved;
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
      // doc comment), so a plain catalog lookup alone cannot see it, and
      // this check would otherwise be silently skipped for one.
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
    final contract = resolvedContract ?? _unambiguousContractFor(rejection);
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
  ///
  /// Round-10 review finding 3: [contract] goes through
  /// [_applicableContractFor], the same unified, ambiguity-aware
  /// resolution `--help` uses, not a bare catalog lookup by the first
  /// entry sharing [CliRejection.consumed]'s words. Two distinct routes
  /// (or a route and a shortcut) can share that same words-only name at
  /// different positional depths (`s` and `s <id> <sub>` are both named
  /// `s`); a bare first-match lookup would attach whichever of them
  /// happened to register first to this error, even when the rejection is
  /// genuinely ambiguous between them, describing a contract this
  /// invocation was never actually one flag away from honouring.
  /// [_unambiguousContractFor] answers `null` for that genuinely ambiguous
  /// case (as well as when nothing resolves at all), so this error is
  /// reported with no `contract` at all rather than a misleading one.
  int _emitRejectionError(CliRejection rejection, {required bool jsonMode}) {
    final exitCode = _exitCodeFor(rejection.kind);
    final contract = _unambiguousContractFor(rejection);
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

  /// The contract a rejection points at, when [_applicableContractFor]'s
  /// unified, ambiguity-aware resolution settles on exactly one: `null`
  /// both when nothing resolves at all and when it stays genuinely
  /// ambiguous (round-10 review finding 3). Every caller that needs a
  /// contract to attach to a rejection, the error path
  /// ([_emitRejectionError]) and the help path's own fallback
  /// ([_emitFocusedHelp]) alike, goes through this rather than a bare
  /// catalog lookup by name: a bare lookup returns only the first entry
  /// sharing that name even when a second, unrelated route or shortcut
  /// shares the exact same words-only name at a different positional
  /// depth, which is exactly the stale contract round-10 finding 3 was
  /// about.
  CommandContract? _unambiguousContractFor(CliRejection rejection) {
    final resolved = _applicableContractFor(rejection);
    return resolved.ambiguous ? null : resolved.contract;
  }

  /// The contract a rejection's own literal-words prefix should actually be
  /// validated and consulted against, when both an ordinary catalog route
  /// and a shortcut can answer to that same prefix at different positional
  /// depths (round-7 review finding 2).
  ///
  /// The old `_contractFor` helper (since deleted, round-10 review finding
  /// 3) and the shortcut lookup's own literal-words fallback each matched
  /// [CliRejection.consumed] on name alone, with no notion of how much
  /// further the invocation itself is still trying to go: an ordinary
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
  /// this no longer asks the old `_contractFor` helper and the old
  /// shortcut-only lookup for one answer each and compares those two. That
  /// helper looked up the catalog by name and, like [CommandCatalog.forName],
  /// returned only the first entry it found, even when two distinct
  /// registered routes share the exact same words-only name (`s` and
  /// `s <id> <sub>` are both named `s`): the other one, possibly the only
  /// one still viable at the missing positional, was never even considered.
  /// The old shortcut-only lookup had the opposite problem: it declared
  /// more than one shortcut sharing a prefix ambiguous immediately, before
  /// ever checking whether only one of them still declares the missing
  /// positional.
  ///
  /// Round-10 review finding 3: `_contractFor` itself is gone now.
  /// [_emitRejectionError] and [_emitFocusedHelp]'s own fallback used to
  /// go through it directly for the error-context contract (rather than
  /// through this method), so the same first-entry-only bug this method
  /// was built to fix for `--help` resolution still reached a rejection's
  /// plain stderr envelope: a genuinely ambiguous rejection between `s`
  /// (no positionals) and `s <id> <sub>` still attached the unrelated
  /// bare `s` contract to the error, even though this method, consulted
  /// for `--help` on the very same rejection, correctly called it
  /// ambiguous. Both callers now go through [_unambiguousContractFor],
  /// which wraps this method and answers `null` for that ambiguous case
  /// too, instead of a stale, misleading contract.
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
  ///
  /// Round-10 review finding 2: [CommandCatalog.allForName] is asked for
  /// the empty prefix too, exactly the same as any other. A route
  /// registered with no literal words at all, only positionals
  /// (`<id> <sub>` mounted at the CLI's own root), has the empty string as
  /// its name, and [CliRejection.consumed] is empty whenever no literal word
  /// was consumed before the rejection fires, which is precisely how such
  /// a route's own ambiguity with a shortcut sharing the same empty
  /// prefix (`<id> <sub> <tail>`) shows up. Skipping the catalog lookup
  /// whenever [CliRejection.consumed] was empty silently dropped that
  /// catalog route from the candidate list while still including any
  /// shortcut sharing the same empty prefix unconditionally, so a
  /// genuinely ambiguous rejection resolved to the shortcut's own help
  /// alone.
  ({CommandContract? contract, bool ambiguous}) _applicableContractFor(
    CliRejection rejection,
  ) {
    final route = rejection.route;
    if (route != null) {
      final catalogContract = _catalog.forRoute(route.pattern);
      final shortcutContract = _shortcutContractsByExactRoute[route.pattern];
      return (contract: catalogContract ?? shortcutContract, ambiguous: false);
    }

    // Round-11 review finding 2: an unknown command names a word the
    // catalog never registered at all; it is never "the beginning of a
    // real route this invocation was one flag away from honouring", unlike
    // every other kind this method still resolves below. Round-10 review
    // finding 2's own fix asks [CommandCatalog.allForName] for the empty
    // prefix exactly like any other, so a bare root route (no literal
    // words, only positionals, or none at all) now resolves as the sole
    // candidate for any rejection whose own consumed prefix happens to be
    // empty too, this one included, attaching that route's own contract to
    // an error that has nothing to do with it. Declared here, per
    // [CliRejection.kind], explicitly, before any candidate is even
    // collected, rather than an ad-hoc check further down: every other kind
    // still means the invocation reached partway into a real route, so it
    // alone keeps consulting the candidate list below, root route
    // included.
    if (rejection.kind == CliRejectionKind.unknownCommand) {
      return (contract: null, ambiguous: false);
    }

    // Round-12 review finding 1: [CliRejectionKind.misplacedOption] can
    // leave [CliRejection.route] null yet still populate
    // [CliRejection.candidates] with the exact, genuinely ambiguous routes
    // still reachable from here (see that field's own doc comment in
    // `cli_router`, on the router's own [CliRejection]). The name-based
    // fallback below resolves by [CliRejection.consumed] alone, which is
    // only the shallower literal prefix every one of those candidates
    // shares (`s`, when the candidates are `s a` and `s b`), never one of
    // the candidates itself: consulted first, it would attach that
    // ancestor route's own contract, one that may not even declare the
    // option this rejection is actually about, to an error that is
    // genuinely ambiguous between its descendants instead.
    //
    // So the per-kind/per-signal resolution this method declares, in
    // order, before any name-based candidate is even collected, is now:
    // [CliRejection.route] non-null resolves to that exact route, always
    // (checked above); [CliRejectionKind.unknownCommand] never resolves a
    // contract, full stop (checked above); non-empty
    // [CliRejection.candidates] resolves from that set alone, the
    // router's own authoritative "these exact routes, and no others, are
    // still reachable" signal (checked here); every other rejection keeps
    // consulting the name-based candidate list below, exactly as before.
    // This does not exclude `misplacedOption` wholesale: a `misplacedOption`
    // whose `candidates` stays empty (a lookahead already singled one
    // route out, or [CliRejection.route] itself was set) still falls
    // through to the very same name-based resolution every other kind
    // uses.
    if (rejection.candidates.isNotEmpty) {
      final resolved = rejection.candidates
          .map(
            (c) =>
                _catalog.forRoute(c.pattern) ??
                _shortcutContractsByExactRoute[c.pattern],
          )
          .whereType<CommandContract>()
          .toList();
      if (resolved.isEmpty) return (contract: null, ambiguous: false);
      if (resolved.length == 1) {
        return (contract: resolved.single, ambiguous: false);
      }
      return (contract: null, ambiguous: true);
    }

    final consumedKey = rejection.consumed.join(' ');
    final candidates = <CommandContract>[
      ..._catalog.allForName(consumedKey),
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

/// Where a [ModularCli]'s own `help` command comes from, resolved exactly
/// once by [ModularCli._resolveHelpProvenance]. See that method's own doc
/// comment for round-13 review findings 1 and 2, which this replaces a
/// per-[ModularCli.run]-call boolean check with.
enum _HelpProvenance {
  /// A developer registered an ordinary route named `help` themselves.
  developerRoute,

  /// A developer registered a shortcut named `help` themselves.
  developerShortcut,

  /// Neither exists: the SDK's own built-in default was registered
  /// instead, the one time this resolved.
  builtin,
}

/// Whether [contract] is named `help`: the exact same rule
/// [CommandContract.name] already applies for [CommandCatalog.forName]
/// (every positional placeholder stripped, required, optional or a
/// wildcard, wherever it falls), applied here to a shortcut's own
/// [CommandContract] too (round-14 review finding 2), so
/// [ModularCli._resolveHelpProvenance] tells a route or a shortcut named
/// `help` apart from the built-in default by one shared predicate,
/// regardless of which of the two registered it or what cardinality its
/// own positional declares.
bool _isNamedHelp(CommandContract contract) => contract.name == 'help';
