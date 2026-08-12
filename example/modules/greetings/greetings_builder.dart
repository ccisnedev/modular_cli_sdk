import 'package:modular_cli_sdk/modular_cli_sdk.dart';

import 'commands/hello.dart';

void buildGreetingsModule(ModuleBuilder m) {
  m.query<HelloInput, HelloOutput>(
    'hello',
    (req) => HelloQuery(HelloInput.fromCliRequest(req)),
    description: 'Say hello to someone',
    params: HelloInput.params,
  );
}
