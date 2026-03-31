import 'package:cli_router/cli_router.dart';
import 'package:modular_cli_sdk/modular_cli_sdk.dart';

// ─── Input DTO ──────────────────────────────────────────────────────────────

/// Version command takes no meaningful input — exists to satisfy the
/// `Command<I, O>` contract uniformly.
class VersionInput extends Input {
  VersionInput();

  factory VersionInput.fromCliRequest(CliRequest req) => VersionInput();

  @override
  Map<String, dynamic> toJson() => {};
}

// ─── Output DTO ─────────────────────────────────────────────────────────────

class VersionOutput extends Output {
  final String version;
  VersionOutput({required this.version});

  @override
  Map<String, dynamic> toJson() => {'version': version};

  @override
  int get exitCode => ExitCode.ok;
}

// ─── Command ────────────────────────────────────────────────────────────────

/// Reports the application version.
class VersionCommand implements Command<VersionInput, VersionOutput> {
  @override
  final VersionInput input;
  VersionCommand(this.input);

  @override
  String? validate() => null;

  @override
  Future<VersionOutput> execute() async =>
      VersionOutput(version: '0.2.0');
}
