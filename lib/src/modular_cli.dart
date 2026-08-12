import 'dart:io' as io;

import 'package:cli_router/cli_router.dart';

import 'approver.dart';
import 'cli_param.dart';
import 'command.dart';
import 'command_catalog.dart';
import 'exit_codes.dart';
import 'help_command.dart';
import 'help_renderer.dart';
import 'input.dart';
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
  ModularCli({Approver? approver, PlanSink? planSink})
    : _approver = approver,
      _planSink = planSink;

  final Approver? _approver;
  final PlanSink? _planSink;

  late final CliRouter _root = CliRouter(onNotFound: _reportUnknownCommand);
  final CommandCatalog _catalog = CommandCatalog();

  /// Every registered route with its declared contract — the single source help
  /// is rendered from.
  CommandCatalog get catalog => _catalog;

  /// Register a named module with its routes.
  ///
  /// [name] becomes the first segment: `name subcommand`.
  ModularCli module(String name, void Function(ModuleBuilder) build) {
    final moduleRouter = CliRouter();
    build(_builderFor(name, moduleRouter));
    _root.mount(name, moduleRouter);
    return this;
  }

  /// Register a root-level [Query] (no module prefix).
  ModularCli query<I extends Input, O extends Output>(
    String route,
    Query<I, O> Function(CliRequest req) queryFactory, {
    String? description,
    List<CliParam>? params,
  }) {
    _builderFor('', _root).query<I, O>(
      route,
      queryFactory,
      description: description,
      params: params,
    );
    return this;
  }

  /// Register a root-level [Command] (no module prefix).
  ///
  /// Root routes have dispatch priority over mounted modules (inherent to
  /// `cli_router`'s two-phase dispatch).
  ModularCli command<I extends Input, O extends Output>(
    String route,
    Command<I, O> Function(CliRequest req) commandFactory, {
    String? description,
    List<CliParam>? params,
  }) {
    _builderFor('', _root).command<I, O>(
      route,
      commandFactory,
      description: description,
      params: params,
    );
    return this;
  }

  ModuleBuilder _builderFor(String name, CliRouter router) => ModuleBuilder(
    moduleName: name,
    router: router,
    catalog: _catalog,
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
  Future<int> run(List<String> args, {io.IOSink? stdout, io.IOSink? stderr}) {
    _registerHelpCommand();
    return _root.run(_routeHelpRequest(args), stdout: stdout, stderr: stderr);
  }

  /// Help must be reachable out of the box — unless the developer wrote their
  /// own `help`, in which case theirs is the CLI's help, everywhere.
  ///
  /// It is a query: it reads the catalog and answers.
  void _registerHelpCommand() {
    if (_catalog.forRoute('help') != null) return;

    query<HelpInput, HelpOutput>(
      'help',
      (req) => HelpQuery(HelpInput(_catalog, focus: req.positionals)),
      description: 'Show the commands this CLI accepts',
    );
  }

  /// Rewrites into the `help` command the help requests no route can serve: the
  /// empty invocation, and a `--help` / `-h` that names no command or names a
  /// module (`cli_router` stops looking for a route at the first flag, and a
  /// module is a mount, not a route).
  ///
  /// The empty invocation is only a help request when nothing claims it. A CLI
  /// may register a root route — a dashboard, a status screen, a banner — and
  /// then bare `<cli>` *is* that route; taking it for help would silently
  /// replace a real command.
  ///
  /// `<command> --help` is left alone: the command's own wrapper answers it, so
  /// an unknown command with `--help` still reaches the error path.
  List<String> _routeHelpRequest(List<String> args) {
    if (args.isEmpty) {
      return _catalog.forRoute('') != null ? args : const ['help'];
    }
    if (!args.any((arg) => arg == '--help' || arg == '-h')) return args;

    final routeTokens = args.takeWhile((arg) => !arg.startsWith('-')).toList();
    if (routeTokens.isEmpty) return ['help', ..._withoutHelpFlags(args)];

    final namesAModule =
        routeTokens.length == 1 &&
        _catalog.forRoute(routeTokens.single) == null &&
        _catalog.forModule(routeTokens.single).isNotEmpty;

    // A command whose route carries positionals (`show <id>`) cannot be matched
    // by the router until they are supplied — so asking for its contract would
    // fall to the error path, forcing the user to provide the very argument he
    // is asking about. Name it and the help answers.
    final contract = _catalog.forName(routeTokens.join(' '));
    final namesAPositionalCommand =
        contract != null && contract.positionals.isNotEmpty;

    return namesAModule || namesAPositionalCommand
        ? ['help', ..._withoutHelpFlags(args)]
        : args;
  }

  /// The `help` command is the request itself; carrying `--help` into it would
  /// make it describe itself instead of what was asked about.
  List<String> _withoutHelpFlags(List<String> args) =>
      args.where((arg) => arg != '--help' && arg != '-h').toList();

  /// The user who mistypes a command is the one who most needs the catalog, so
  /// the error path shows exactly what `help` shows — only on stderr, and as a
  /// failure.
  ///
  /// It tells apart two things that are not the same. An invocation naming the
  /// **beginning of a registered route** is not unknown: what it lacks is the
  /// end. `math` where `math add` exists, or `api graphql` where
  /// `api graphql compile` does, are both that — a prefix with no ending, and
  /// the catalog knows it. Calling both cases "unknown command" sent the user
  /// looking for a typo they had not made, and answered with the whole catalog
  /// when a handful of lines were the relevant ones.
  int _reportUnknownCommand(CliNotFound notFound) {
    final attempted = notFound.args
        .takeWhile((arg) => !arg.startsWith('-'))
        .join(' ');

    final completions = _completionsOf(attempted);

    // A catalog holding only the completions, rendered by the same renderer as
    // everything else. Narrowing the renderer's input rather than teaching it a
    // new shape keeps "the renderer is the only place help text is produced"
    // true, and adds nothing to the package's public surface.
    notFound.stderr
      ..writeln(
        completions.isEmpty
            ? "Error: unknown command '$attempted'."
            : "Error: '$attempted' is not a complete command.",
      )
      ..writeln()
      ..writeln(
        HelpRenderer(
          completions.isEmpty ? _catalog : _narrowedTo(completions),
        ).renderCatalog(),
      );
    return ExitCode.invalidUsage;
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
    _root.printHelp(sink, title: title);
  }
}
