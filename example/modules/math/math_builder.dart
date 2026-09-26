import 'package:modular_cli_sdk/modular_cli_sdk.dart';

import 'commands/add.dart';
import 'commands/multiply.dart';

void buildMathModule(ModuleBuilder m) {
  m.query<AddInput, AddOutput>(
    'add',
    (req) => AddQuery(AddInput.fromCliRequest(req)),
    globals: true,
    description: 'Add two numbers',
    contract: AddInput.contract,
  );

  m.query<AddInput, AddOutput>(
    'multiply',
    (req) => MultiplyQuery(AddInput.fromCliRequest(req)),
    globals: true,
    description: 'Multiply two numbers',
    contract: AddInput.contract,
  );
}
