import 'package:cli_router/cli_router.dart';
import 'package:modular_cli_sdk/modular_cli_sdk.dart';

/// The **root command** — the one the bare invocation runs (`dart run
/// example/example.dart` with no arguments).
///
/// A CLI may claim the empty invocation for a dashboard, a status screen or a
/// banner. When it does, the bare invocation is that command, not a help
/// request; `help` (or `--help`) is how the user asks for the catalog.

// ─── Input DTO ──────────────────────────────────────────────────────────────

class StatusInput extends Input {
  StatusInput();

  factory StatusInput.fromCliRequest(CliRequest req) => StatusInput();

  @override
  Map<String, dynamic> toJson() => {};
}

// ─── Output DTO ─────────────────────────────────────────────────────────────

class StatusOutput extends Output {
  final String name;
  final String version;

  StatusOutput({required this.name, required this.version});

  @override
  Map<String, dynamic> toJson() => {'name': name, 'version': version};

  @override
  int get exitCode => ExitCode.ok;

  @override
  String? toText() =>
      '$name $version\n'
      '\n'
      "Run 'help' to see the commands this CLI accepts.";
}

// ─── Command ────────────────────────────────────────────────────────────────

class StatusCommand implements Command<StatusInput, StatusOutput> {
  @override
  final StatusInput input;

  StatusCommand(this.input);

  @override
  String? validate() => null;

  @override
  Future<StatusOutput> execute() async =>
      StatusOutput(name: 'modular_cli_sdk example', version: 'v0.3.1');
}
