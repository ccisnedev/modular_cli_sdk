import 'package:modular_cli_sdk/modular_cli_sdk.dart';

import 'commands/hello.dart';

void buildGreetingsModule(ModuleBuilder m) {
  m.command<HelloInput, HelloOutput>(
    'hello',
    (req) => HelloCommand(HelloInput.fromCliRequest(req)),
    description: 'Say hello to someone',
  );
}
