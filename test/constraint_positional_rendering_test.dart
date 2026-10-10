import 'dart:convert';
import 'dart:io';

import 'package:cli_router/cli_router.dart';
import 'package:modular_cli_sdk/modular_cli_sdk.dart';
import 'package:test/test.dart';

// Issue #43: `ExactlyOne` and `MutuallyExclusive` rendered every field as
// `--flag`, even a declared positional, so the rejection named an option
// that does not exist (`Choose one of: --program, --file, --stdin`). A
// positional now renders as `<name>`, an option as `--name`, in declared
// order. Constraints over options only produce exactly what they did.

CliContract _contract(List<CliConstraint> constraints) => CliContract(
  positionals: [CliPositional.string('program', required: false)],
  options: [
    CliParam.flag('file', abbr: null, repeatable: false),
    CliParam.flag('stdin', abbr: null, repeatable: false),
  ],
  constraints: constraints,
);

String _message(CliContract contract, Set<String> present) {
  try {
    contract.validateConstraints(present);
  } on CommandException catch (e) {
    return e.message;
  }
  fail('expected a rejection for $present');
}

class _RpnInput extends Input {
  @override
  Map<String, dynamic> toJson() => {};
}

class _RpnOutput extends Output {
  @override
  Map<String, dynamic> toJson() => {};

  @override
  int get exitCode => ExitCode.ok;
}

class _RpnQuery implements Query<_RpnInput, _RpnOutput> {
  @override
  final _RpnInput input = _RpnInput();

  @override
  String? validate() => null;

  @override
  Future<_RpnOutput> execute() async => _RpnOutput();
}

ModularCli _buildCli() {
  final cli = ModularCli(suggestionDistance: 2, name: 'cx', version: '1.0.0');
  cli.module('eval', (m) {
    m.query<_RpnInput, _RpnOutput>(
      'rpn [<program>]',
      (req) => _RpnQuery(),
      globals: true,
      description: 'Evaluate an RPN expression',
      contract: _contract(const [
        ExactlyOne(['program', 'file', 'stdin']),
      ]),
    );
  });
  return cli;
}

Future<({int exitCode, String stderr})> _run(List<String> args) async {
  final out = _TestSink();
  final err = _TestSink();
  final code = await _buildCli().run(args, stdout: out, stderr: err);
  return (exitCode: code, stderr: err.toString());
}

void main() {
  group('ExactlyOne renders each field by its declared kind (issue 43)', () {
    final contract = _contract(const [
      ExactlyOne(['program', 'file', 'stdin']),
    ]);

    test('none present: a positional as <name>, options as --name', () {
      expect(
        _message(contract, const {}),
        equals('Choose one of: <program>, --file, --stdin'),
      );
    });

    test('two or more present: the "got" part renders the same way', () {
      expect(
        _message(contract, const {'program', 'stdin'}),
        equals(
          'Choose one of: <program>, --file, --stdin, '
          'got <program>, --stdin',
        ),
      );
    });
  });

  group('MutuallyExclusive renders each field by its declared kind', () {
    test('a positional as <name>, an option as --name', () {
      final contract = _contract(const [
        MutuallyExclusive(['program', 'stdin']),
      ]);

      expect(
        _message(contract, const {'program', 'stdin'}),
        equals(
          '<program> and --stdin cannot be combined, got <program>, --stdin',
        ),
      );
    });
  });

  group('constraints over options only are unchanged (issue 43)', () {
    final contract = _contract(const [
      ExactlyOne(['file', 'stdin']),
      MutuallyExclusive(['file', 'stdin']),
    ]);

    test('ExactlyOne with none present', () {
      expect(
        _message(contract, const {}),
        equals('Choose one of: --file, --stdin'),
      );
    });

    test('ExactlyOne with several present', () {
      expect(
        _message(
          _contract(const [
            ExactlyOne(['file', 'stdin']),
          ]),
          const {'file', 'stdin'},
        ),
        equals('Choose one of: --file, --stdin, got --file, --stdin'),
      );
    });

    test('MutuallyExclusive with several present', () {
      expect(
        _message(
          _contract(const [
            MutuallyExclusive(['file', 'stdin']),
          ]),
          const {'file', 'stdin'},
        ),
        equals('--file and --stdin cannot be combined, got --file, --stdin'),
      );
    });

    test('check() called directly keeps its option-only rendering', () {
      expect(
        const ExactlyOne(['file', 'stdin']).check(const {}),
        equals('Choose one of: --file, --stdin'),
      );
    });
  });

  group('end to end through a contract with a positional (issue 43)', () {
    test('nothing given names the positional as <program>', () async {
      final result = await _run(['eval', 'rpn']);

      expect(result.exitCode, equals(ExitCode.validationFailed));
      expect(
        result.stderr,
        contains(
          'Choose one of: <program>, --file, --stdin [validation-failed]',
        ),
      );
    });

    test('two sources name the positional as <program> too', () async {
      final result = await _run(['eval', 'rpn', '--stdin', '1 2 +']);

      expect(result.exitCode, equals(ExitCode.validationFailed));
      expect(result.stderr, contains('got <program>, --stdin'));
      expect(result.stderr, isNot(contains('--program')));
    });

    test('toJson of the constraints is unchanged', () {
      expect(const ExactlyOne(['program', 'file']).toJson(), {
        'kind': 'exactlyOne',
        'fields': ['program', 'file'],
      });
      expect(const MutuallyExclusive(['program', 'file']).toJson(), {
        'kind': 'mutuallyExclusive',
        'fields': ['program', 'file'],
      });
    });
  });
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
