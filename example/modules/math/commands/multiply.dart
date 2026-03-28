import 'package:modular_cli_sdk/modular_cli_sdk.dart';

import 'add.dart';

/// Multiply two numbers — reuses [AddInput] and [AddOutput] from add.dart.
class MultiplyCommand implements Command<AddInput, AddOutput> {
  @override
  final AddInput input;
  MultiplyCommand(this.input);

  @override
  String? validate() => null;

  @override
  Future<AddOutput> execute() async => AddOutput(
    result: input.a * input.b,
    operation: '${input.a} * ${input.b}',
  );
}
