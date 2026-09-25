// A third review of PR #29 (feat/0.6.0), after the first ten findings and
// the second review's seven were fixed, found three more concrete defects
// (a fourth, a test-quality gap in the first review's shortcut regression
// test, is fixed directly in test/pr29_review_findings_test.dart instead of
// here, since it names no new lib behavior of its own).
//
// Findings are numbered to match that third review, 1 through 3.

import 'dart:convert';

import 'package:modular_cli_sdk/modular_cli_sdk.dart';
import 'package:test/test.dart';

import 'doubles.dart';

// ── Finding 1 fixture: a shortcut carrying its own option contract ────────

class _WidgetInput extends Input {
  @override
  Map<String, dynamic> toJson() => {};
}

class _WidgetOutput extends Output {
  @override
  Map<String, dynamic> toJson() => {'ok': true};

  @override
  int get exitCode => ExitCode.ok;
}

class _WidgetQuery implements Query<_WidgetInput, _WidgetOutput> {
  _WidgetQuery(this.input);

  @override
  final _WidgetInput input;

  @override
  String? validate() => null;

  @override
  Future<_WidgetOutput> execute() async => _WidgetOutput();
}

ModularCli _buildShortcutValidationCli() {
  final cli = ModularCli(suggestionDistance: 2);
  cli.query<_WidgetInput, _WidgetOutput>(
    'widget',
    (req) => _WidgetQuery(_WidgetInput()),
    globals: true,
    description: 'The shortcut target',
    contract: CliContract.none,
  );
  cli.shortcut(
    's',
    target: 'widget',
    globals: true,
    contract: CliContract(
      options: [
        CliParam.integer(
          'a',
          abbr: null,
          required: false,
          repeatable: false,
          defaultValue: null,
          description: 'An integer the shortcut declares itself',
        ),
        CliParam.string(
          'b',
          abbr: null,
          required: true,
          repeatable: false,
          defaultValue: null,
          description: 'A required string the shortcut declares itself',
        ),
      ],
    ),
  );
  return cli;
}

void main() {
  group(
    'finding 1: an invalid shortcut option value must not lose to --help',
    () {
      test(
        's --json --a bad --help reports the bad --a value instead of '
        'granting help, even though the shortcut is absent from the '
        'catalog and --b (required) was also omitted',
        () async {
          final result = await _runWith(_buildShortcutValidationCli(), [
            's',
            '--json',
            '--a',
            'bad',
            '--help',
          ]);

          expect(result.exitCode, equals(ExitCode.validationFailed));
          final envelope = jsonDecode(result.stderr) as Map<String, dynamic>;
          final error = envelope['error'] as Map<String, dynamic>;
          expect(error['id'], equals('validation-failed'));
          expect(error['message'], contains('--a'));
        },
      );

      test('a well-typed --a still lets --help win when --b is missing', () async {
        final result = await _runWith(_buildShortcutValidationCli(), [
          's',
          '--a',
          '1',
          '--help',
        ]);

        expect(result.exitCode, equals(ExitCode.ok));
      });
    },
  );
}

// ── Test harness shared by every group ─────────────────────────────────────

Future<({int exitCode, String stdout, String stderr})> _runWith(
  ModularCli cli,
  List<String> args,
) async {
  final out = MemorySink();
  final err = MemorySink();
  final code = await cli.run(args, stdout: out, stderr: err);
  return (exitCode: code, stdout: out.output, stderr: err.output);
}
