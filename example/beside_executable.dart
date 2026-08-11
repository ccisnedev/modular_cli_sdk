/// example/beside_executable.dart
/// A CLI that needs something beside its own executable — and therefore behaves
/// differently depending on how you run it.
///
/// This example exists to make one failure visible. A compiled Dart CLI finds
/// `Platform.resolvedExecutable` pointing at itself, so anything it locates
/// relative to that is found where it was installed. Run the same code through
/// `dart run`, and `resolvedExecutable` is the *Dart* binary: the CLI looks for
/// its assets inside the Dart SDK, does not find them, and reports a broken
/// installation that is not broken.
///
/// The layout it expects is the one an installed CLI has — the binary in `bin/`,
/// with `assets/` beside it:
///
/// ```
/// <root>/bin/beside_executable
/// <root>/assets/greeting.txt
/// ```
///
/// Build and run it that way:
///
/// ```bash
/// dart compile exe example/beside_executable.dart -o <root>/bin/beside_executable
/// mkdir <root>/assets && echo "Hello from the assets folder" > <root>/assets/greeting.txt
/// <root>/bin/beside_executable greet
/// ```
///
/// Then try `dart run example/beside_executable.dart greet` and read what it
/// says. That difference is the whole point of this file.
library;

import 'dart:io';

import 'package:cli_router/cli_router.dart';
import 'package:modular_cli_sdk/modular_cli_sdk.dart';

// ─── Assets ──────────────────────────────────────────────────────────────────

/// The root the CLI resolves its assets against: the directory containing
/// `bin/`, derived from wherever this executable actually is.
///
/// Deliberately not configurable. A CLI whose asset resolution can be
/// overridden is a CLI whose answers depend on the shell it was launched from,
/// and two ways of resolving one thing is the ambiguity this example exists to
/// show rather than to add.
Directory get _root => File(Platform.resolvedExecutable).parent.parent;

File get _greetingFile => File('${_root.path}/assets/greeting.txt');

// ─── Input DTO ───────────────────────────────────────────────────────────────

class GreetInput extends Input {
  GreetInput();

  factory GreetInput.fromCliRequest(CliRequest req) => GreetInput();

  @override
  Map<String, dynamic> toJson() => {};
}

// ─── Output DTO ──────────────────────────────────────────────────────────────

class GreetOutput extends Output {
  final String greeting;
  GreetOutput({required this.greeting});

  @override
  Map<String, dynamic> toJson() => {'greeting': greeting};

  @override
  int get exitCode => ExitCode.ok;
}

// ─── Command ─────────────────────────────────────────────────────────────────

/// Reads a greeting from `<root>/assets/greeting.txt`.
class GreetCommand implements Command<GreetInput, GreetOutput> {
  @override
  final GreetInput input;
  GreetCommand(this.input);

  @override
  String? validate() => null;

  @override
  Future<GreetOutput> execute() async {
    if (!_greetingFile.existsSync()) {
      // Naming the cause is the point. The defect this example demonstrates is
      // not that the file is missing — it is that a CLI in this situation
      // usually reports a broken installation and lets you go looking for one.
      throw CommandException(
        code: 'ASSETS_NOT_FOUND',
        message:
            'no assets/ folder beside this executable: the CLI is running from source',
        exitCode: ExitCode.notFound,
        details: {
          'lookedFor': _greetingFile.path,
          'resolvedExecutable': Platform.resolvedExecutable,
        },
      );
    }
    return GreetOutput(greeting: _greetingFile.readAsStringSync().trim());
  }
}

// ─── CLI ─────────────────────────────────────────────────────────────────────

Future<void> main(List<String> args) async {
  final code = await runBesideExecutable(args);
  exit(code);
}

Future<int> runBesideExecutable(
  List<String> args, {
  IOSink? stdout,
  IOSink? stderr,
}) async {
  final cli = ModularCli();

  cli.command<GreetInput, GreetOutput>(
    'greet',
    (req) => GreetCommand(GreetInput.fromCliRequest(req)),
    description: 'Read the greeting shipped beside this executable',
  );

  return cli.run(args, stdout: stdout, stderr: stderr);
}
