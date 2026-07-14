import 'package:cli_router/cli_router.dart';
import 'package:modular_cli_sdk/modular_cli_sdk.dart';

// ─── Input DTO ──────────────────────────────────────────────────────────────

class HelloInput extends Input {
  final String name;
  HelloInput({required this.name});

  /// The command's contract, declared once: help renders it and the framework
  /// enforces it, so `--name` can never mean one thing in help and another here.
  static final params = [
    CliParam.string(
      'name',
      abbr: 'n',
      defaultValue: 'World',
      description: 'Who to greet',
    ),
  ];

  factory HelloInput.fromCliRequest(CliRequest req) =>
      HelloInput(name: req.flagString('name')!);

  @override
  List<CliParam> get schemaFields => params;

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
