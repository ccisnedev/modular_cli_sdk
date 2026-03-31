/// example/example.dart
/// Minimal runnable example — mirrors example/example.dart from modular_api.
///
/// Run:
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

import 'commands/version.dart';
import 'modules/greetings/greetings_builder.dart';
import 'modules/math/math_builder.dart';

// ─── CLI ─────────────────────────────────────────────────────────────────────

Future<void> main(List<String> args) async {
  final code = await runExample(args);
  exit(code);
}

Future<int> runExample(List<String> args) async {
  final cli = ModularCli();

  // Root-level commands
  cli.command<VersionInput, VersionOutput>(
    'version',
    (req) => VersionCommand(VersionInput.fromCliRequest(req)),
    description: 'Print application version',
  );

  // Module-scoped commands
  cli.module('greetings', buildGreetingsModule);
  cli.module('math', buildMathModule);

  return cli.run(args);
}
