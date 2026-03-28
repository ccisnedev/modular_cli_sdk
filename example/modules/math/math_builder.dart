import 'package:modular_cli_sdk/modular_cli_sdk.dart';

import 'commands/add.dart';
import 'commands/multiply.dart';

void buildMathModule(ModuleBuilder m) {
  m.command<AddInput, AddOutput>(
    'add',
    (req) => AddCommand(AddInput.fromCliRequest(req)),
    description: 'Add two numbers',
  );

  m.command<AddInput, AddOutput>(
    'multiply',
    (req) => MultiplyCommand(AddInput.fromCliRequest(req)),
    description: 'Multiply two numbers',
  );
}
