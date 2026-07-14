import 'dart:io' as io;

import 'package:cli_router/cli_router.dart';

import 'cli_param.dart';
import 'command.dart';
import 'command_catalog.dart';
import 'exit_codes.dart';
import 'help_command.dart';
import 'help_renderer.dart';
import 'input.dart';
import 'module_builder.dart';
import 'output.dart';

/// Entry point for a modular CLI application.
///
/// Analogous to `ModularApi` in modular_api — orchestrates modules, applies
/// middleware, handles global flags (`--json`, `--quiet`), and dispatches
/// commands via `cli_router`.
///
/// ```dart
/// final cli = ModularCli();
///
/// // Root-level commands (no module prefix)
/// cli.command<VersionInput, VersionOutput>(
///   'version',
///   (req) => VersionCommand(VersionInput.fromCliRequest(req)),
///   description: 'Print version info',
/// );
///
/// // Module-scoped commands
/// cli.module('greetings', (m) {
///   m.command('hello', (req) => GreetCommand(GreetInput.fromCliRequest(req)),
///     description: 'Say hello');
/// });
///
/// final exitCode = await cli.run(args);
/// ```
class ModularCli {
  ModularCli();

  late final CliRouter _root = CliRouter(onNotFound: _reportUnknownCommand);
  final CommandCatalog _catalog = CommandCatalog();

  /// Every registered command with its declared contract — the single source
  /// help is rendered from.
  CommandCatalog get catalog => _catalog;

  /// Register a named module with its commands.
  ///
  /// [name] becomes the first segment of the command: `name subcommand`.
  /// [build] receives a [ModuleBuilder] for registering commands.
  ModularCli module(String name, void Function(ModuleBuilder) build) {
    final moduleRouter = CliRouter();
    final builder = ModuleBuilder(
      moduleName: name,
      router: moduleRouter,
      catalog: _catalog,
    );
    build(builder);
    _root.mount(name, moduleRouter);
    return this;
  }

  /// Register a root-level command (no module prefix).
  ///
  /// [route] becomes a top-level segment: `route [--flags]`.
  /// The command passes through the full [Command] lifecycle:
  /// input → validate → execute → format via [CliOutput].
  ///
  /// Root commands have dispatch priority over mounted modules
  /// (inherent to `cli_router`'s two-phase dispatch).
  ModularCli command<I extends Input, O extends Output>(
    String route,
    Command<I, O> Function(CliRequest req) commandFactory, {
    String? description,
    List<CliParam>? params,
  }) {
    // Reuse ModuleBuilder lifecycle — moduleName is unused at runtime.
    final builder = ModuleBuilder(
      moduleName: '',
      router: _root,
      catalog: _catalog,
    );
    builder.command<I, O>(
      route,
      commandFactory,
      description: description,
      params: params,
    );
    return this;
  }

  /// Add a shelf-like middleware to the root router.
  ///
  /// Middlewares are applied in registration order and wrap all commands
  /// across all modules.
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
  void _registerHelpCommand() {
    if (_catalog.forRoute('help') != null) return;

    command<HelpInput, HelpOutput>(
      'help',
      (req) => HelpCommand(HelpInput(_catalog, focus: req.positionals)),
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

    return namesAModule ? ['help', ..._withoutHelpFlags(args)] : args;
  }

  /// The `help` command is the request itself; carrying `--help` into it would
  /// make it describe itself instead of what was asked about.
  List<String> _withoutHelpFlags(List<String> args) =>
      args.where((arg) => arg != '--help' && arg != '-h').toList();

  /// The user who mistypes a command is the one who most needs the catalog, so
  /// the error path shows exactly what `help` shows — only on stderr, and as a
  /// failure.
  int _reportUnknownCommand(CliNotFound notFound) {
    final attempted = notFound.args
        .takeWhile((arg) => !arg.startsWith('-'))
        .join(' ');

    notFound.stderr
      ..writeln("Error: unknown command '$attempted'.")
      ..writeln()
      ..writeln(HelpRenderer(_catalog).renderCatalog());
    return ExitCode.invalidUsage;
  }

  /// Print the help listing for all registered modules and commands.
  void printHelp(io.IOSink sink, {String? title}) {
    _root.printHelp(sink, title: title);
  }
}
