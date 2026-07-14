/// example/example.dart
/// Minimal runnable example — mirrors example/example.dart from modular_api.
///
/// Run:
///   dart run example/example.dart                  # the root command
///   dart run example/example.dart help             # the command catalog
///   dart run example/example.dart help --json      # the catalog as JSON
///   dart run example/example.dart version
///   dart run example/example.dart version --json
///   dart run example/example.dart greetings hello --name World
///   dart run example/example.dart greetings hello --name World --json
///   dart run example/example.dart math add --a 3 --b 7
///   dart run example/example.dart math add --a 3 --b 7 --json
///   dart run example/example.dart math multiply --a 4 --b 5 --json
library;

import 'dart:io';

import 'package:modular_cli_sdk/modular_cli_sdk.dart';

import 'commands/status.dart';
import 'commands/version.dart';
import 'modules/greetings/greetings_builder.dart';
import 'modules/math/math_builder.dart';

// ─── CLI ─────────────────────────────────────────────────────────────────────

Future<void> main(List<String> args) async {
  final code = await runExample(args);
  exit(code);
}

Future<int> runExample(
  List<String> args, {
  IOSink? stdout,
  IOSink? stderr,
}) async {
  final cli = ModularCli();

  // The root command — what the bare invocation runs. Registering it means this
  // CLI, not the help, owns the empty invocation.
  cli.command<StatusInput, StatusOutput>(
    '',
    (req) => StatusCommand(StatusInput.fromCliRequest(req)),
    description: 'Show the CLI status',
  );

  // Root-level commands
  cli.command<VersionInput, VersionOutput>(
    'version',
    (req) => VersionCommand(VersionInput.fromCliRequest(req)),
    description: 'Print application version',
  );

  // Module-scoped commands
  cli.module('greetings', buildGreetingsModule);
  cli.module('math', buildMathModule);

  return cli.run(args, stdout: stdout, stderr: stderr);
}
