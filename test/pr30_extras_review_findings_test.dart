// Codex review of PR #30 at 373cc64 found two issues in the
// CommandException extraFields/extraLines mechanism (feat: c1fe75d).
//
// Finding 1 (module_builder.dart:731): only ModuleBuilder._reject forwarded
// a recorded CommandException's own extraFields/extraLines into
// InvocationOutcome. Every other path that records an error, a use()
// middleware's own thrown CommandException, a step's own thrown
// CommandException, and the copy _carryOut makes to attach discrepancies
// onto a step failure in --json mode, recorded it through
// recordInvocationError alone, silently dropping extraFields (lost from the
// JSON envelope) and extraLines (lost from the text-mode render). Fixed
// structurally: recordInvocationError itself now reads a recorded error's
// own extraFields/extraLines and carries them into the outcome, so every
// call site gets this for free instead of each one having to remember two
// further calls; the discrepancy-attaching copy also now copies
// extraFields/extraLines forward from the exception it copies.
//
// Finding 2 (command_exception.dart:66): extraFields was never checked
// against the reserved envelope field names id/message/exitCode/details,
// the exact keys CommandException's own toJson() always writes: a caller
// passing extraFields: {'id': null, 'message': []} silently corrupted the
// envelope once spread over it. The constructor now rejects a colliding key
// with an ArgumentError at construction time, deriving the reserved set
// from toJson() itself rather than a hand-written list, so it cannot drift
// out of sync with what toJson() actually emits.

import 'dart:convert';

import 'package:modular_cli_sdk/modular_cli_sdk.dart';
import 'package:test/test.dart';

import 'doubles.dart';

/// A command whose first step reports something other than it claimed
/// (a discrepancy), then whose second step throws [error]: exactly the
/// shape ModuleBuilder._carryOut copies to attach discrepancies onto a step
/// failure in --json mode (module_builder.dart lines 551-561).
class _DiscrepancyThenFailureCommand implements Command<TouchInput, TouchOutput> {
  _DiscrepancyThenFailureCommand(this.error);

  final CommandException error;

  @override
  final TouchInput input = TouchInput();

  @override
  String? validate() => null;

  @override
  Future<List<Step>> steps() async => [
    FakeStep(verb: 'create', target: 'a.txt', reportedVerb: 'keep'),
    FakeStep(verb: 'create', target: 'b.txt', throws: error),
  ];

  @override
  TouchOutput describe(Execution execution) =>
      TouchOutput(execution.outcomes.map((o) => o.target).toList());
}

/// A query whose body throws straight out of execute(): the classic path
/// through ModuleBuilder._mount's own catch, forwarded by _reject. Kept as
/// a baseline so the refactor in _reject does not regress the one boundary
/// that already worked before this round.
class _ThrowingQuery implements Query<CountInput, CountOutput> {
  _ThrowingQuery(this.error);

  final CommandException error;

  @override
  final CountInput input = CountInput(1);

  @override
  String? validate() => null;

  @override
  Future<CountOutput> execute() async => throw error;
}

ModularCli _cliWithMiddlewareThrowing(CommandException error) {
  final cli = ModularCli(suggestionDistance: 2);
  cli.use((next) => (req) async => throw error);
  cli.query<CountInput, CountOutput>(
    'count',
    (req) => CountQuery(CountInput(1)),
    globals: true,
    contract: CliContract.none,
  );
  return cli;
}

ModularCli _cliWithThrowingQuery(CommandException error) {
  final cli = ModularCli(suggestionDistance: 2);
  cli.query<CountInput, CountOutput>(
    'count',
    (req) => _ThrowingQuery(error),
    globals: true,
    contract: CliContract.none,
  );
  return cli;
}

ModularCli _cliWithTouchCommand(Command<TouchInput, TouchOutput> command) {
  final cli = ModularCli(suggestionDistance: 2);
  cli.command<TouchInput, TouchOutput>(
    'touch',
    (req) => command,
    globals: true,
    contract: CliContract.none,
  );
  return cli;
}

void main() {
  group('finding 1: extraFields/extraLines survive every recording path, '
      'not only ModuleBuilder._reject', () {
    group('a use() middleware\'s own thrown CommandException', () {
      test('keeps extraFields in the --json envelope', () async {
        final cli = _cliWithMiddlewareThrowing(
          CommandException(
            id: 'blocked',
            message: 'blocked by policy',
            exitCode: ExitCode.unauthorized,
            extraFields: {'policy': 'no-weekends'},
          ),
        );

        final err = MemorySink();
        final code = await cli.run(['count', '--json'], stderr: err);

        expect(code, equals(ExitCode.unauthorized));
        final envelope = jsonDecode(err.output) as Map<String, dynamic>;
        final error = envelope['error'] as Map<String, dynamic>;
        expect(error['policy'], equals('no-weekends'));
      });

      test('keeps extraLines after the rendered error line in text mode', () async {
        final cli = _cliWithMiddlewareThrowing(
          CommandException(
            id: 'blocked',
            message: 'blocked by policy',
            exitCode: ExitCode.unauthorized,
            extraLines: 'See the weekend policy for detail.',
          ),
        );

        final err = MemorySink();
        final code = await cli.run(['count'], stderr: err);

        expect(code, equals(ExitCode.unauthorized));
        expect(err.output, contains('See the weekend policy for detail.'));
      });
    });

    group("a step's own thrown CommandException, with no discrepancy before it", () {
      test('keeps extraFields in the --json envelope', () async {
        final cli = _cliWithTouchCommand(
          TouchCommand(
            TouchInput(),
            targets: const ['a.txt'],
            error: CommandException(
              id: 'disk-full',
              message: 'no space left on device',
              exitCode: ExitCode.dataError,
              extraFields: {'device': '/dev/sda1'},
            ),
          ),
        );

        final err = MemorySink();
        final code = await cli.run(
          ['touch', '--apply', '--autoapprove', '--json'],
          stderr: err,
        );

        expect(code, equals(ExitCode.dataError));
        final envelope = jsonDecode(err.output) as Map<String, dynamic>;
        final error = envelope['error'] as Map<String, dynamic>;
        expect(error['device'], equals('/dev/sda1'));
      });

      test('keeps extraLines in text mode', () async {
        final cli = _cliWithTouchCommand(
          TouchCommand(
            TouchInput(),
            targets: const ['a.txt'],
            error: CommandException(
              id: 'disk-full',
              message: 'no space left on device',
              exitCode: ExitCode.dataError,
              extraLines: 'Free some space and try again.',
            ),
          ),
        );

        final err = MemorySink();
        final code = await cli.run(
          ['touch', '--apply', '--autoapprove'],
          stderr: err,
        );

        expect(code, equals(ExitCode.dataError));
        expect(err.output, contains('Free some space and try again.'));
      });
    });

    group('the copy _carryOut makes to attach discrepancies onto a step '
        'failure in --json mode', () {
      test("keeps the step exception's own extraFields alongside the "
          'attached discrepancies', () async {
        final cli = _cliWithTouchCommand(
          _DiscrepancyThenFailureCommand(
            CommandException(
              id: 'disk-full',
              message: 'no space left on device',
              exitCode: ExitCode.dataError,
              extraFields: {'device': '/dev/sda1'},
            ),
          ),
        );

        final err = MemorySink();
        final code = await cli.run(
          ['touch', '--apply', '--autoapprove', '--json'],
          stderr: err,
        );

        expect(code, equals(ExitCode.dataError));
        final envelope = jsonDecode(err.output) as Map<String, dynamic>;
        final error = envelope['error'] as Map<String, dynamic>;
        expect(error['device'], equals('/dev/sda1'));
        // The discrepancy attachment itself must not have regressed either.
        expect(error['details']['discrepancies'], isNotEmpty);
      });

      test('keeps extraLines in text mode, alongside the reported '
          'discrepancy', () async {
        final cli = _cliWithTouchCommand(
          _DiscrepancyThenFailureCommand(
            CommandException(
              id: 'disk-full',
              message: 'no space left on device',
              exitCode: ExitCode.dataError,
              extraLines: 'Free some space and try again.',
            ),
          ),
        );

        final err = MemorySink();
        final code = await cli.run(
          ['touch', '--apply', '--autoapprove'],
          stderr: err,
        );

        expect(code, equals(ExitCode.dataError));
        expect(err.output, contains('Free some space and try again.'));
      });
    });

    group('regression: ModuleBuilder._reject itself, refactored to lean on '
        "recordInvocationError's own forwarding", () {
      test("still forwards a rejected query's own extraFields", () async {
        final cli = _cliWithThrowingQuery(
          CommandException(
            id: 'checks-failed',
            message: 'some checks failed',
            exitCode: ExitCode.genericError,
            extraFields: {
              'checks': [
                {'name': 'disk', 'ok': false},
              ],
            },
          ),
        );

        final err = MemorySink();
        final code = await cli.run(['count', '--json'], stderr: err);

        expect(code, equals(ExitCode.genericError));
        final envelope = jsonDecode(err.output) as Map<String, dynamic>;
        final error = envelope['error'] as Map<String, dynamic>;
        expect(error['checks'], [
          {'name': 'disk', 'ok': false},
        ]);
      });

      test("still forwards a rejected query's own extraLines", () async {
        final cli = _cliWithThrowingQuery(
          CommandException(
            id: 'checks-failed',
            message: 'some checks failed',
            exitCode: ExitCode.genericError,
            extraLines: 'Run doctor for a full report.',
          ),
        );

        final err = MemorySink();
        final code = await cli.run(['count'], stderr: err);

        expect(code, equals(ExitCode.genericError));
        expect(err.output, contains('Run doctor for a full report.'));
      });
    });
  });

  group('finding 2: extraFields must not collide with a reserved envelope '
      'field name', () {
    test('rejects a colliding "id" key', () {
      expect(
        () => CommandException(
          id: 'x',
          message: 'm',
          exitCode: 1,
          extraFields: {'id': 'overwritten'},
        ),
        throwsArgumentError,
      );
    });

    test('rejects a colliding "message" key', () {
      expect(
        () => CommandException(
          id: 'x',
          message: 'm',
          exitCode: 1,
          extraFields: {'message': []},
        ),
        throwsArgumentError,
      );
    });

    test('rejects a colliding "exitCode" key', () {
      expect(
        () => CommandException(
          id: 'x',
          message: 'm',
          exitCode: 1,
          extraFields: {'exitCode': 0},
        ),
        throwsArgumentError,
      );
    });

    test('rejects a colliding "details" key', () {
      expect(
        () => CommandException(
          id: 'x',
          message: 'm',
          exitCode: 1,
          extraFields: {'details': 'nope'},
        ),
        throwsArgumentError,
      );
    });

    test('accepts extraFields whose keys collide with none of them', () {
      expect(
        () => CommandException(
          id: 'x',
          message: 'm',
          exitCode: 1,
          extraFields: {
            'checks': [
              {'name': 'disk', 'ok': true},
            ],
          },
        ),
        returnsNormally,
      );
    });
  });
}
