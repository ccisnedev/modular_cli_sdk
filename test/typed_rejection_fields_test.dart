// The SDK used to recover two pieces of information by parsing
// CliRejection.message (documented as "for logging") with regexes: the
// missing positional's name, and the offending argv token used to build
// "Did you mean" suggestions. cli_router 0.2.0 now exposes both typed,
// as CliRejection.argument and CliRejection.token; this test proves the
// SDK reads the typed field instead of parsing the message.
//
// The regex `_withSuggestion` used, RegExp("'([^']*)'"), is unanchored and
// stops at the FIRST closing quote in the message. If the offending token
// itself contains an apostrophe, the regex truncates it there, producing a
// shorter, wrong word to look up in the suggestion catalog. rejection.token,
// in contrast, is always the complete token exactly as written on argv.
//
// Typing "s'how" instead of "show" exploits exactly that: the router's
// message contains the full token inside single quotes, so a regex over
// the message extracts only "s" (edit distance 3 from "show", outside the
// configured maxDistance of 2, so no suggestion is produced), while
// rejection.token holds "s'how" in full (edit distance 1 from "show", well
// inside maxDistance, so the suggestion fires). This test fails under the
// old, message-parsing implementation and passes once the SDK reads
// rejection.token directly instead.
import 'package:cli_router/cli_router.dart';
import 'package:modular_cli_sdk/modular_cli_sdk.dart';
import 'package:test/test.dart';

import 'doubles.dart';

class _ItemInput extends Input {
  _ItemInput(this.id);
  final int id;

  factory _ItemInput.fromCliRequest(CliRequest req) =>
      _ItemInput(int.parse(req.param('id')!));

  @override
  Map<String, dynamic> toJson() => {'id': id};
}

class _ItemOutput extends Output {
  _ItemOutput(this.id);
  final int id;

  @override
  Map<String, dynamic> toJson() => {'id': id};

  @override
  int get exitCode => ExitCode.ok;
}

class _ItemCommand implements Query<_ItemInput, _ItemOutput> {
  _ItemCommand(this.input);

  @override
  final _ItemInput input;

  @override
  String? validate() => null;

  @override
  Future<_ItemOutput> execute() async => _ItemOutput(input.id);
}

ModularCli _buildCli() {
  final cli = ModularCli(suggestionDistance: 2);
  cli.module('commands', (m) {
    m.query<_ItemInput, _ItemOutput>(
      'show <id>',
      (req) => _ItemCommand(_ItemInput.fromCliRequest(req)),
      globals: true,
      description: 'Show a record',
      contract: CliContract(
        positionals: [CliPositional.integer('id', required: true)],
      ),
    );
  });
  return cli;
}

void main() {
  test(
    'a typo containing an apostrophe still finds the suggestion, because '
    'the SDK reads CliRejection.token instead of parsing the message (a '
    'regex over the message would truncate at the embedded apostrophe and '
    'find only "s", too far from "show" to suggest it)',
    () async {
      final out = MemorySink();
      final err = MemorySink();
      final code = await _buildCli().run(
        ['commands', "s'how", '5'],
        stdout: out,
        stderr: err,
      );

      expect(code, isNot(equals(ExitCode.ok)));
      expect(err.output, contains("Did you mean 'show'?"));
    },
  );
}
