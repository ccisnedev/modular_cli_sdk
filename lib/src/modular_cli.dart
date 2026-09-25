import 'dart:convert';
import 'dart:io' as io;

import 'package:cli_router/cli_router.dart';

import 'approver.dart';
import 'cli_contract.dart';
import 'command.dart';
import 'command_catalog.dart';
import 'exit_codes.dart';
import 'global_options.dart';
import 'help_command.dart';
import 'help_renderer.dart';
import 'input.dart';
import 'module_builder.dart';
import 'output.dart';
import 'plan.dart';
import 'query.dart';
import 'route_pattern.dart';

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
  ModularCli({Approver? approver, PlanSink? planSink})
    : _approver = approver,
      _planSink = planSink;

  final Approver? _approver;
  final PlanSink? _planSink;

  late final CliRouter _root = CliRouter(globalOptions: globalOptionSpecs);
  final CommandCatalog _catalog = CommandCatalog();

  /// Every registered route's dispatch handler, keyed by
  /// [CommandContract.name]. Shared by every [ModuleBuilder] this instance
  /// builds, so [shortcut] can find a target route's handler no matter
  /// which module registered it.
  final Map<String, CliHandler> _handlersByName = {};

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
  /// prefix to be exactly one literal word, and `''` splits into zero — so
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
  /// [contract] defaults to [CliContract.none] — see [ModuleBuilder.query].
  ModularCli query<I extends Input, O extends Output>(
    String route,
    Query<I, O> Function(CliRequest req) queryFactory, {
    required bool globals,
    String? description,
    CliContract contract = CliContract.none,
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
  /// [contract] defaults to [CliContract.none] — see [ModuleBuilder.command].
  ModularCli command<I extends Input, O extends Output>(
    String route,
    Command<I, O> Function(CliRequest req) commandFactory, {
    required bool globals,
    String? description,
    CliContract contract = CliContract.none,
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
  /// already registered for [target] — the full name of a route already
  /// registered via [query], [command] or [ModuleBuilder], e.g. `'eval
  /// rpn'` — but under [pattern]'s own, independently declared [contract]
  /// and [globals] scope (issue #27 section 4: "a declared route that runs
  /// the target's handler with a narrower contract").
  ///
  /// This is for a route that means the same thing as a longer one but is
  /// spelled differently and more narrowly —
  /// `cli.shortcut('&lt;program&gt;', target: 'eval rpn', globals: false)`
  /// lets a bare program argument alone run exactly what
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
  /// One consequence: `--help` and JSON error `contract` fields are not
  /// available through a shortcut route itself; a caller is directed to
  /// [target]'s own help.
  ///
  /// Throws [ArgumentError] if [target] has not been registered yet —
  /// shortcuts must be declared after their target.
  ModularCli shortcut(
    String pattern, {
    required String target,
    required bool globals,
    CliContract contract = CliContract.none,
    String? description,
  }) {
    final handler = _handlersByName[target];
    if (handler == null) {
      throw ArgumentError(
        'shortcut("$pattern") targets "$target", which is not a '
        'registered route. Register the target with query(), command() or '
        'a ModuleBuilder before declaring a shortcut to it.',
      );
    }
    validateContractPositionals(pattern, contract);
    _root.cmd(
      pattern,
      handler,
      options: contract.toOptionSpecs(),
      globals: globals,
      description: description,
    );
    return this;
  }

  /// The registered route word closest to [word] — see
  /// [CommandCatalog.suggest].
  String? suggest(String word, {int maxDistance = 2}) =>
      _catalog.suggest(word, maxDistance: maxDistance);

  ModuleBuilder _builderFor(String name, CliRouter router) => ModuleBuilder(
    moduleName: name,
    router: router,
    catalog: _catalog,
    handlersByName: _handlersByName,
    approver: _approver,
    planSink: _planSink,
  );

  /// Add a shelf-like middleware to the root router.
  ///
  /// Middlewares are applied in registration order and wrap all routes across
  /// all modules.
  ModularCli use(CliMiddleware middleware) {
    _root.use(middleware);
    return this;
  }

  /// Dispatch [args] through the router and return an exit code.
  ///
  /// Pass custom [stdout] / [stderr] sinks for testing.
  Future<int> run(
    List<String> args, {
    io.IOSink? stdout,
    io.IOSink? stderr,
  }) async {
    _registerHelpCommand();
    final out = stdout ?? io.stdout;
    final err = stderr ?? io.stderr;

    // A bare invocation is a help request only when nothing else claims it —
    // a CLI may register its own root route (a dashboard, a status screen),
    // and bare `<cli>` is then that route, not a request for help.
    if (args.isEmpty && _catalog.forRoute('') == null) {
      out.writeln(HelpRenderer(_catalog).renderCatalog());
      return ExitCode.ok;
    }

    return _root.run(
      args,
      onReject: (rejection) => _handleRejection(rejection, out, err),
      stdout: out,
      stderr: err,
    );
  }

  /// Help must be reachable out of the box — unless the developer wrote their
  /// own `help`, in which case theirs is the CLI's help, everywhere.
  ///
  /// It is a query: it reads the catalog and answers. Registered with a
  /// trailing wildcard so a focus — `help math add` — is collected as [rest]
  /// rather than having to be a declared positional.
  void _registerHelpCommand() {
    if (_catalog.forName('help') != null) return;

    query<HelpInput, HelpOutput>(
      'help *',
      (req) => HelpQuery(HelpInput(_catalog, focus: req.rest)),
      globals: true,
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
  //     trails off partway through a real route" — [CliRejectionKind.incomplete],
  //     [CliRejectionKind.missingArgument] and
  //     [CliRejectionKind.missingRequiredOption]. These are exactly the cases
  //     where what the user is missing is the information `--help` would have
  //     given them anyway.
  //   * It never wins for a genuine shape error — an unknown command, an extra
  //     argument, an unknown/misplaced/malformed option, a repeated one. Those
  //     are told about what is actually wrong; `--help` having been typed
  //     alongside a typo does not make the typo not worth mentioning.
  //
  // Read straight off left-to-right parsing: whichever failure is hit first
  // decides both the [CliRejectionKind] and which options — `--help` among
  // them — had already been read when it was hit.

  static const _helpWinsKinds = {
    CliRejectionKind.incomplete,
    CliRejectionKind.missingArgument,
    CliRejectionKind.missingRequiredOption,
  };

  /// Kinds that mean the invocation's *shape* was wrong — command words or
  /// argument count — as opposed to a problem with one specific option.
  /// Mapped to [ExitCode.invalidUsage] (64); everything else, an option the
  /// user got wrong, is mapped to [ExitCode.validationFailed] (7) — the
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

  /// Machine-readable counterpart of [_exitCodeFor], in the same
  /// `SCREAMING_SNAKE_CASE` a [CommandException.code] uses, so a caller
  /// parsing `--json` output sees one error vocabulary regardless of whether
  /// the rejection came from `cli_router` itself or from a handler.
  String _errorCodeFor(CliRejectionKind kind) =>
      _structuralKinds.contains(kind) ? 'INVALID_USAGE' : 'VALIDATION_FAILED';

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

  int _handleRejection(CliRejection rejection, io.IOSink out, io.IOSink err) {
    final helpRequested = rejection.options.any((o) => o.spec.name == 'help');
    final jsonMode = rejection.options.any((o) => o.spec.name == 'json');

    if (helpRequested && _helpWinsKinds.contains(rejection.kind)) {
      return _emitFocusedHelp(rejection, out, jsonMode: jsonMode);
    }
    return _emitRejectionError(rejection, err, jsonMode: jsonMode);
  }

  /// Help for a rejection `--help` won: the most specific thing the router
  /// could still identify — the command itself, then the module it belongs
  /// to, then, when neither is known, the full catalog (narrowed to
  /// completions of what was typed, exactly as the plain error path does).
  int _emitFocusedHelp(
    CliRejection rejection,
    io.IOSink out, {
    required bool jsonMode,
  }) {
    final contract = _contractFor(rejection);
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
  /// `api graphql compile` does, are both that — a prefix with no ending,
  /// and the catalog knows it. Calling both cases "unknown command" sent the
  /// user looking for a typo they had not made, and answered with the whole
  /// catalog when a handful of lines were the relevant ones.
  int _emitRejectionError(
    CliRejection rejection,
    io.IOSink err, {
    required bool jsonMode,
  }) {
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
    // router itself would say — it is a specific, answerable thing.
    //
    // This rewrite applies to [CliRejectionKind.incomplete] alone: it is
    // the one kind that means "trails off partway through a real route",
    // which is exactly what "is not a complete command" describes. Every
    // other kind — `eval --json --bogus` is `unknownOption`, not
    // `incomplete` — keeps the router's own message untouched: nothing
    // here rewrites a message keyed on anything but the kind.
    final routerMessage = rejection.message ?? rejection.kind.name;
    final message = _withSuggestion(
      rejection.kind,
      routerMessage,
      rejection.kind == CliRejectionKind.incomplete &&
              contract == null &&
              completions.isNotEmpty
          ? "'$attempted' is not a complete command"
          : routerMessage,
    );

    if (jsonMode) {
      final details = _detailsFor(rejection, contract);
      err.writeln(
        jsonEncode({
          'error': _errorCodeFor(rejection.kind),
          'message': message,
          'exitCode': exitCode,
          'isRetryable': false,
          'kind': rejection.kind.name,
          if (contract != null) 'contract': contract.toJson(),
          if (details != null) 'details': details,
        }),
      );
      return exitCode;
    }

    err.writeln('Error: $message');

    if (contract != null) {
      err
        ..writeln()
        ..writeln(HelpRenderer(_catalog).renderCommand(contract));
      return exitCode;
    }

    err
      ..writeln()
      ..writeln(
        HelpRenderer(
          completions.isEmpty ? _catalog : _narrowedTo(completions),
        ).renderCatalog(),
      );
    return exitCode;
  }

  /// Appends a "did you mean" suggestion to [finalMessage] when [kind] is
  /// one naming an offending word — [CliRejectionKind.unknownCommand]
  /// (`"unknown command 'shwo'"`) or [CliRejectionKind.incomplete]
  /// (`"'shwo' does not continue this command"`) — and [CommandCatalog.suggest]
  /// finds a close enough registered word for it.
  ///
  /// The word is read from [routerMessage] — the router's own, original
  /// message, always quoted the same way for these two kinds — never from
  /// [finalMessage], which may already have been rewritten (the "is not a
  /// complete command" case above) into text that no longer quotes a
  /// single word. Gated on [kind] alone, exactly like the rewrite above: it
  /// is an addition, not a substitution, so it cannot change what the
  /// router itself reported, only add a suggestion after it.
  String _withSuggestion(
    CliRejectionKind kind,
    String routerMessage,
    String finalMessage,
  ) {
    if (kind != CliRejectionKind.unknownCommand &&
        kind != CliRejectionKind.incomplete) {
      return finalMessage;
    }
    final match = RegExp("'([^']*)'").firstMatch(routerMessage);
    if (match == null) return finalMessage;
    final offending = match.group(1)!;
    if (offending.isEmpty) return finalMessage;
    final suggestion = _catalog.suggest(offending);
    if (suggestion == null) return finalMessage;
    return "$finalMessage. Did you mean '$suggestion'?";
  }

  /// The contract a rejection points at: the route `cli_router` itself named
  /// ([CliRejection.route], set for [CliRejectionKind.missingRequiredOption]
  /// among others), or, failing that, the route named by the words already
  /// consumed — the case `cli_router` could not yet identify a specific
  /// route for ([CliRejectionKind.incomplete], [CliRejectionKind.missingArgument]).
  CommandContract? _contractFor(CliRejection rejection) {
    final route = rejection.route;
    if (route != null) return _catalog.forRoute(route.pattern);
    if (rejection.consumed.isEmpty) return null;
    return _catalog.forName(rejection.consumed.join(' '));
  }

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
