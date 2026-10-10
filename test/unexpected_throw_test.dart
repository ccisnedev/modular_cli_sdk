import 'dart:convert';

import 'package:modular_cli_sdk/modular_cli_sdk.dart';
import 'package:test/test.dart';

import 'doubles.dart';

// Issue #25: a throw that is not a CommandException is answered with a clean
// error and exit code 1, never an exception escaping run().

class _PlanningBoom implements Command<TouchInput, TouchOutput> {
  @override
  final TouchInput input = TouchInput();

  @override
  String? validate() => null;

  @override
  Future<List<Step>> steps() async => throw StateError('no route to host');

  @override
  TouchOutput describe(Execution execution) => TouchOutput(const []);
}

class _DescribeBoom implements Command<TouchInput, TouchOutput> {
  @override
  final TouchInput input = TouchInput();

  @override
  String? validate() => null;

  @override
  Future<List<Step>> steps() async => [FakeStep(verb: 'create', target: 'a')];

  @override
  TouchOutput describe(Execution execution) =>
      throw FormatException('malformed response');
}

class _QueryBoom implements Query<TouchInput, TouchOutput> {
  @override
  final TouchInput input = TouchInput();

  @override
  String? validate() => null;

  @override
  Future<TouchOutput> execute() async => throw StateError('no route to host');
}

ModularCli _cli(Command<TouchInput, TouchOutput> command) =>
    ModularCli(suggestionDistance: 2)..command<TouchInput, TouchOutput>(
      'boom',
      (req) => command,
      globals: true,
      contract: CliContract.none,
    );

ModularCli _queryCli() => ModularCli(suggestionDistance: 2)
  ..query<TouchInput, TouchOutput>(
    'boom',
    (req) => _QueryBoom(),
    globals: true,
    contract: CliContract.none,
  );

Map<String, dynamic> _errorOf(MemorySink err) =>
    (jsonDecode(err.output) as Map<String, dynamic>)['error']
        as Map<String, dynamic>;

void main() {
  group('a throw from steps()', () {
    test('returns exit code 1 and a clean error under --plan', () async {
      final err = MemorySink();
      final code = await _cli(
        _PlanningBoom(),
      ).run(['boom', '--plan'], stdout: MemorySink(), stderr: err);

      expect(code, ExitCode.genericError);
      expect(err.output, contains('no route to host'));
      expect(err.output, contains('Nothing was changed'));
      expect(err.output, isNot(contains('#0')));
    });

    test('says nothing ran, under --apply', () async {
      final err = MemorySink();
      final code = await _cli(_PlanningBoom()).run(
        ['boom', '--apply', '--autoapprove'],
        stdout: MemorySink(),
        stderr: err,
      );

      expect(code, ExitCode.genericError);
      expect(err.output, contains('Nothing was changed'));
    });

    test('is a structured error under --json', () async {
      final err = MemorySink();
      final code = await _cli(
        _PlanningBoom(),
      ).run(['boom', '--plan', '--json'], stdout: MemorySink(), stderr: err);

      expect(code, ExitCode.genericError);
      final error = _errorOf(err);
      expect(error['id'], 'unexpected-error');
      expect(error['message'], contains('no route to host'));
      expect(error['message'], contains('Nothing was changed'));
    });
  });

  group('a throw after the plan was approved', () {
    test('returns exit code 1 and says the run had started', () async {
      final err = MemorySink();
      final code = await _cli(_DescribeBoom()).run(
        ['boom', '--apply', '--autoapprove'],
        stdout: MemorySink(),
        stderr: err,
      );

      expect(code, ExitCode.genericError);
      expect(err.output, contains('malformed response'));
      expect(err.output, contains('may have been applied'));
    });

    test('is a structured error under --json', () async {
      final err = MemorySink();
      final code = await _cli(_DescribeBoom()).run(
        ['boom', '--apply', '--autoapprove', '--json'],
        stdout: MemorySink(),
        stderr: err,
      );

      expect(code, ExitCode.genericError);
      final error = _errorOf(err);
      expect(error['id'], 'unexpected-error');
      expect(error['message'], contains('may have been applied'));
    });
  });

  group('a throw from a query', () {
    test('returns exit code 1 and a clean error', () async {
      final err = MemorySink();
      final code = await _queryCli().run(['boom'], stderr: err);

      expect(code, ExitCode.genericError);
      expect(err.output, contains('no route to host'));
    });

    test('is a structured error under --json', () async {
      final err = MemorySink();
      final code = await _queryCli().run(['boom', '--json'], stderr: err);

      expect(code, ExitCode.genericError);
      expect(_errorOf(err)['id'], 'unexpected-error');
    });
  });
}
