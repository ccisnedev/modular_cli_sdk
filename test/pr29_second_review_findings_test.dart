// An independent second review of PR #29 (feat/0.6.0), after the first ten
// findings were fixed, found seven more concrete defects. Each group below
// reproduces the exact failure described in the review, then asserts the
// corrected behavior.
//
// Findings are numbered to match that second review, 1 through 7.

import 'dart:convert';
import 'dart:io';

import 'package:cli_router/cli_router.dart';
import 'package:modular_cli_sdk/modular_cli_sdk.dart';
import 'package:test/test.dart';

import 'doubles.dart';

// ── Finding 2 fixture: `math add`, a required --b and an optional --a whose
//    value can be badly typed ─────────────────────────────────────────────

class _MathInput extends Input {
  _MathInput({required this.a, required this.b});

  final int? a;
  final int b;

  static final contract = CliContract(
    options: [
      CliParam.integer(
        'a',
        abbr: null,
        required: false,
        repeatable: false,
        defaultValue: null,
        description: 'First addend',
      ),
      CliParam.integer(
        'b',
        abbr: null,
        required: true,
        repeatable: false,
        defaultValue: null,
        description: 'Second addend',
      ),
    ],
  );

  factory _MathInput.fromCliRequest(CliRequest req) =>
      _MathInput(a: req.flagInt('a'), b: req.flagInt('b')!);

  @override
  Map<String, dynamic> toJson() => {'a': a, 'b': b};
}

class _MathOutput extends Output {
  _MathOutput(this.sum);
  final int sum;

  @override
  Map<String, dynamic> toJson() => {'sum': sum};

  @override
  int get exitCode => ExitCode.ok;
}

class _MathAddQuery implements Query<_MathInput, _MathOutput> {
  _MathAddQuery(this.input);

  @override
  final _MathInput input;

  @override
  String? validate() => null;

  @override
  Future<_MathOutput> execute() async => _MathOutput((input.a ?? 0) + input.b);
}

ModularCli _buildMathCli() {
  final cli = ModularCli(suggestionDistance: 2);
  cli.module('math', (m) {
    m.query<_MathInput, _MathOutput>(
      'add',
      (req) => _MathAddQuery(_MathInput.fromCliRequest(req)),
      globals: true,
      description: 'Add two integers',
      contract: _MathInput.contract,
    );
  });
  return cli;
}

// ── Finding 3 fixture: a shortcut to a Command, not a Query ───────────────

ModularCli _buildTouchShortcutCli(Command<TouchInput, TouchOutput> command) {
  final cli = ModularCli(suggestionDistance: 2, approver: (_) async => true);
  cli.command<TouchInput, TouchOutput>(
    'touch',
    (req) => command,
    globals: true,
    description: 'Touch things',
    contract: CliContract.none,
  );
  cli.shortcut('t', target: 'touch', globals: true, contract: CliContract.none);
  return cli;
}

void main() {
  group('finding 2: an invalid supplied option value wins over --help', () {
    test(
      'math add --json --a bad --help reports the bad --a value instead '
      'of granting help, even though --b (required) was also omitted',
      () async {
        final result = await _runWith(_buildMathCli(), [
          'math',
          'add',
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

    test(
      'a well-typed --a still lets --help win when --b is missing',
      () async {
        final result = await _runWith(_buildMathCli(), [
          'math',
          'add',
          '--a',
          '1',
          '--help',
        ]);

        expect(result.exitCode, equals(ExitCode.ok));
        expect(result.stdout, contains('math add'));
      },
    );
  });

  group('finding 3: a shortcut to a Command inherits its ChangeFlags', () {
    test('--plan through the shortcut shows what would change', () async {
      final result = await _runWith(
        _buildTouchShortcutCli(TouchCommand(TouchInput())),
        ['t', '--plan'],
      );

      expect(result.exitCode, equals(ExitCode.ok));
      expect(result.stdout, contains('create   a.txt'));
    });

    test('--apply through the shortcut carries the plan out', () async {
      final command = TouchCommand(TouchInput());
      final result = await _runWith(_buildTouchShortcutCli(command), [
        't',
        '--apply',
        '--autoapprove',
      ]);

      expect(result.exitCode, equals(ExitCode.ok));
      expect(command.built.single.performed, isTrue);
      expect(result.stdout, contains('touched: a.txt'));
    });
  });
}

// ── Helpers ─────────────────────────────────────────────────────────────────

Future<({int exitCode, String stdout, String stderr})> _runWith(
  ModularCli cli,
  List<String> args,
) async {
  final out = _TestSink();
  final err = _TestSink();
  final code = await cli.run(args, stdout: out, stderr: err);
  return (exitCode: code, stdout: out.toString(), stderr: err.toString());
}

class _TestSink implements IOSink {
  final _buffer = StringBuffer();

  @override
  void write(Object? object) => _buffer.write(object);
  @override
  void writeln([Object? object = '']) => _buffer.writeln(object);
  @override
  void writeAll(Iterable objects, [String separator = '']) =>
      _buffer.writeAll(objects, separator);
  @override
  void writeCharCode(int charCode) => _buffer.writeCharCode(charCode);
  @override
  void add(List<int> data) {}
  @override
  void addError(Object error, [StackTrace? stackTrace]) {}
  @override
  Future addStream(Stream<List<int>> stream) => Future.value();
  @override
  Future flush() => Future.value();
  @override
  Future close() => Future.value();
  @override
  Future get done => Future.value();
  @override
  Encoding get encoding => utf8;
  @override
  set encoding(Encoding value) {}

  @override
  String toString() => _buffer.toString();
}
