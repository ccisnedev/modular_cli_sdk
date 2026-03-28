import 'package:cli_router/cli_router.dart';
import 'package:modular_cli_sdk/modular_cli_sdk.dart';

// ─── Input DTO ──────────────────────────────────────────────────────────────

class HelloInput extends Input {
  final String name;
  HelloInput({required this.name});

  factory HelloInput.fromCliRequest(CliRequest req) =>
      HelloInput(name: req.flagString('name') ?? 'World');

  @override
  Map<String, dynamic> toJson() => {'name': name};
}

// ─── Output DTO ─────────────────────────────────────────────────────────────

class HelloOutput extends Output {
  final String greeting;
  HelloOutput({required this.greeting});

  @override
  Map<String, dynamic> toJson() => {'greeting': greeting};

  @override
  int get exitCode => ExitCode.ok;
}

// ─── Command ────────────────────────────────────────────────────────────────

class HelloCommand implements Command<HelloInput, HelloOutput> {
  @override
  final HelloInput input;
  HelloCommand(this.input);

  @override
  String? validate() => null;

  @override
  Future<HelloOutput> execute() async =>
      HelloOutput(greeting: 'Hello, ${input.name}!');
}
