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

// ── Finding 3 fixture: a step that misreports, followed by one that throws ─

/// Two steps: the first claims one thing and reports another (a
/// [Discrepancy]), the second throws outright (a [StepFailure]). Exercises
/// both channels PreviewExecutor.perform() can report trouble through, in
/// the same run.
class _DiscrepancyThenFailureCommand
    implements Command<TouchInput, TouchOutput> {
  _DiscrepancyThenFailureCommand(this.input);

  @override
  final TouchInput input;

  @override
  String? validate() => null;

  @override
  Future<List<Step>> steps() async => [
    FakeStep(verb: 'create', target: 'a.txt', reportedVerb: 'replace'),
    FakeStep(verb: 'create', target: 'b.txt', throws: Exception('boom')),
  ];

  @override
  TouchOutput describe(Execution execution) =>
      TouchOutput(execution.outcomes.map((o) => o.target).toList());
}

ModularCli _buildDiscrepancyFailureCli() {
  final cli = ModularCli(suggestionDistance: 2, approver: (_) async => true);
  cli.command<TouchInput, TouchOutput>(
    'thing',
    (req) => _DiscrepancyThenFailureCommand(TouchInput()),
    globals: true,
    description: 'A command whose steps misreport and then fail',
    contract: CliContract.none,
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

  group(
    'finding 2: a middleware that throws while building its own handler '
    'must not escape run()',
    () {
      test('a synchronous throw from the outer (next) { ... } body is '
          'caught, not just one from the returned inner handler', () async {
        final cli = ModularCli(suggestionDistance: 2);
        cli.query<_WidgetInput, _WidgetOutput>(
          'widget',
          (req) => _WidgetQuery(_WidgetInput()),
          globals: true,
          description: 'A route to dispatch middleware through',
          contract: CliContract.none,
        );
        cli.use(
          (next) {
            // Thrown while the middleware is still being built, before the
            // returned handler is ever invoked with a request.
            throw CommandException(
              id: 'middleware-construction-blew-up',
              message: 'the middleware failed while building its handler',
              exitCode: ExitCode.conflict,
            );
          },
        );

        final err = MemorySink();
        final code = await cli.run(['widget'], stderr: err);

        expect(code, equals(ExitCode.conflict));
        expect(err.output, contains('middleware-construction-blew-up'));
        expect(
          err.output,
          contains('the middleware failed while building its handler'),
        );
      });

      test('writes the structured envelope under --json', () async {
        final cli = ModularCli(suggestionDistance: 2);
        cli.query<_WidgetInput, _WidgetOutput>(
          'widget',
          (req) => _WidgetQuery(_WidgetInput()),
          globals: true,
          description: 'A route to dispatch middleware through',
          contract: CliContract.none,
        );
        cli.use(
          (next) {
            throw CommandException(
              id: 'middleware-construction-blew-up',
              message: 'the middleware failed while building its handler',
              exitCode: ExitCode.conflict,
            );
          },
        );

        final err = MemorySink();
        final code = await cli.run(['widget', '--json'], stderr: err);

        expect(code, equals(ExitCode.conflict));
        final envelope = jsonDecode(err.output) as Map<String, dynamic>;
        final error = envelope['error'] as Map<String, dynamic>;
        expect(error['id'], equals('middleware-construction-blew-up'));
        expect(error['exitCode'], equals(ExitCode.conflict));
      });
    },
  );

  group(
    'finding 3: a discrepancy followed by a step failure must not corrupt '
    'JSON stderr',
    () {
      test(
        'stderr under --json decodes as a single JSON document, with the '
        "discrepancy folded into the failure's own envelope",
        () async {
          final result = await _runWith(_buildDiscrepancyFailureCli(), [
            'thing',
            '--apply',
            '--autoapprove',
            '--json',
          ]);

          expect(result.exitCode, equals(ExitCode.genericError));

          // Decoding the whole of stderr as one JSON document is only
          // possible when no raw, non-JSON text (the "! ..." discrepancy
          // line) was written ahead of the error envelope.
          final envelope = jsonDecode(result.stderr) as Map<String, dynamic>;
          final error = envelope['error'] as Map<String, dynamic>;
          expect(error['id'], equals('step-failed'));

          final details = error['details'] as Map<String, dynamic>;
          final discrepancies = details['discrepancies'] as List;
          expect(discrepancies, hasLength(1));
          final discrepancy = discrepancies.single as Map<String, dynamic>;
          expect(discrepancy['index'], equals(0));

          // stdout is unaffected: still a single decodable JSON document.
          jsonDecode(result.stdout);
        },
      );
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
