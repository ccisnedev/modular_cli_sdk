import 'package:modular_cli_sdk/modular_cli_sdk.dart';

import 'commands/write.dart';

void buildNotesModule(ModuleBuilder m) {
  // Registered with `command`, not `query` — so the SDK declares `--plan`,
  // `--apply` and `--autoapprove` on it, enforces that one of the first two is
  // given, takes the approval, and checks what the steps did against what they
  // said. None of that is written here.
  m.command<WriteNoteInput, WriteNoteOutput>(
    'write <name>',
    (req) => WriteNoteCommand(WriteNoteInput.fromCliRequest(req)),
    description: 'Write a note',
    params: WriteNoteInput.params,
  );
}
