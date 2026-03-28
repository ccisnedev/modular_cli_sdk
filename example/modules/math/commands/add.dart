import 'package:cli_router/cli_router.dart';
import 'package:modular_cli_sdk/modular_cli_sdk.dart';

// ─── Input DTO ──────────────────────────────────────────────────────────────

class AddInput extends Input {
  final int a;
  final int b;
  AddInput({required this.a, required this.b});

  factory AddInput.fromCliRequest(CliRequest req) =>
      AddInput(a: req.flagInt('a') ?? 0, b: req.flagInt('b') ?? 0);

  @override
  Map<String, dynamic> toJson() => {'a': a, 'b': b};
}

// ─── Output DTO ─────────────────────────────────────────────────────────────

class AddOutput extends Output {
  final int result;
  final String operation;
  AddOutput({required this.result, required this.operation});

  @override
  Map<String, dynamic> toJson() => {'operation': operation, 'result': result};

  @override
  int get exitCode => ExitCode.ok;
}

// ─── Command ────────────────────────────────────────────────────────────────

class AddCommand implements Command<AddInput, AddOutput> {
  @override
  final AddInput input;
  AddCommand(this.input);

  @override
  String? validate() => null;

  @override
  Future<AddOutput> execute() async => AddOutput(
    result: input.a + input.b,
    operation: '${input.a} + ${input.b}',
  );
}
