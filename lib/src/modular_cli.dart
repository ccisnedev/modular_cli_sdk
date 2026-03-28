import 'dart:io' as io;

import 'package:cli_router/cli_router.dart';

import 'module_builder.dart';

/// Entry point for a modular CLI application.
///
/// Analogous to `ModularApi` in modular_api — orchestrates modules, applies
/// middleware, handles global flags (`--json`, `--quiet`), and dispatches
/// commands via `cli_router`.
///
/// ```dart
/// final cli = ModularCli();
/// cli.module('greetings', (m) {
///   m.command('hello', (req) => GreetCommand(GreetInput.fromCliRequest(req)),
///     description: 'Say hello');
/// });
/// final exitCode = await cli.run(args);
/// ```
class ModularCli {
  ModularCli();

  final CliRouter _root = CliRouter();

  /// Register a named module with its commands.
  ///
  /// [name] becomes the first segment of the command: `name subcommand`.
  /// [build] receives a [ModuleBuilder] for registering commands.
  ModularCli module(String name, void Function(ModuleBuilder) build) {
    final moduleRouter = CliRouter();
    final builder = ModuleBuilder(moduleName: name, router: moduleRouter);
    build(builder);
    _root.mount(name, moduleRouter);
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
    return _root.run(args, stdout: stdout, stderr: stderr);
  }

  /// Print the help listing for all registered modules and commands.
  void printHelp(io.IOSink sink, {String? title}) {
    _root.printHelp(sink, title: title);
  }
}
