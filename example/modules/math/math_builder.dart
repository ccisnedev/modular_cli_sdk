import 'package:modular_cli_sdk/modular_cli_sdk.dart';

import 'commands/add.dart';
import 'commands/multiply.dart';

void buildMathModule(ModuleBuilder m) {
  m.query<AddInput, AddOutput>(
    'add',
    (req) => AddQuery(AddInput.fromCliRequest(req)),
    description: 'Add two numbers',
    params: AddInput.params,
  );

  m.query<AddInput, AddOutput>(
    'multiply',
    (req) => MultiplyQuery(AddInput.fromCliRequest(req)),
    description: 'Multiply two numbers',
    params: AddInput.params,
  );
}
