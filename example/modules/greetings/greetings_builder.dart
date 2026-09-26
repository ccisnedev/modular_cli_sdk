import 'package:modular_cli_sdk/modular_cli_sdk.dart';

import 'commands/hello.dart';

void buildGreetingsModule(ModuleBuilder m) {
  m.query<HelloInput, HelloOutput>(
    'hello',
    (req) => HelloQuery(HelloInput.fromCliRequest(req)),
    globals: true,
    description: 'Say hello to someone',
    contract: HelloInput.contract,
  );
}
