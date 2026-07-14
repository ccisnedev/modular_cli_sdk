import 'dart:convert';
import 'dart:io';

import 'package:cli_router/cli_router.dart';
import 'package:modular_cli_sdk/modular_cli_sdk.dart';
import 'package:test/test.dart';

class _AddInput extends Input {
  final int a;
  final int b;
  _AddInput({required this.a, required this.b});

  static final params = [
    CliParam.integer(
      'a',
      abbr: 'a',
      required: true,
      description: 'First operand',
    ),
    CliParam.integer(
      'b',
      abbr: 'b',
      required: true,
      description: 'Second operand',
    ),
  ];

  factory _AddInput.fromCliRequest(CliRequest req) =>
      _AddInput(a: req.flagInt('a')!, b: req.flagInt('b')!);

  @override
  List<CliParam> get schemaFields => params;

  @override
  Map<String, dynamic> toJson() => {'a': a, 'b': b};
}

class _SumOutput extends Output {
  final int result;
  _SumOutput(this.result);

  @override
  Map<String, dynamic> toJson() => {'result': result};

  @override
  int get exitCode => ExitCode.ok;
}

class _AddCommand implements Command<_AddInput, _SumOutput> {
  @override
  final _AddInput input;
  _AddCommand(this.input);

  @override
  String? validate() => null;

  @override
  Future<_SumOutput> execute() async => _SumOutput(input.a + input.b);
}

ModularCli _buildCli() {
  final cli = ModularCli();
  cli.module('math', (m) {
    m.command<_AddInput, _SumOutput>(
      'add',
      (req) => _AddCommand(_AddInput.fromCliRequest(req)),
      description: 'Add two numbers',
      params: _AddInput.params,
    );
  });
  return cli;
}

Future<({int exitCode, String stdout, String stderr})> _run(
  List<String> args,
) async {
  final out = _TestSink();
  final err = _TestSink();
  final code = await _buildCli().run(args, stdout: out, stderr: err);
  return (exitCode: code, stdout: out.toString(), stderr: err.toString());
}

void main() {
  group('an unknown command is an error, and the error is helpful', () {
    test('names the offending command on stderr with exit 64', () async {
      final result = await _run(['bogus']);

      expect(result.exitCode, equals(ExitCode.invalidUsage));
      expect(result.stdout, isEmpty);
      expect(result.stderr, contains('bogus'));
    });

    test('renders the SDK catalog, not the router listing', () async {
      final result = await _run(['bogus']);

      expect(result.stderr, contains('math add'));
      expect(result.stderr, contains('Add two numbers'));
      expect(result.stderr, contains('Global options'));
      expect(
        result.stderr,
        isNot(contains('Command not found or invalid usage.')),
        reason: "the router's own listing must no longer be printed",
      );
    });

    test('shows the same commands the successful help shows', () async {
      final error = await _run(['bogus']);
      final help = await _run(['help']);

      for (final route in ['math add', 'help']) {
        expect(help.stdout, contains(route));
        expect(error.stderr, contains(route));
      }
    });

    test('an unknown command inside a module is caught too', () async {
      final result = await _run(['math', 'bogus']);

      expect(result.exitCode, equals(ExitCode.invalidUsage));
      expect(result.stderr, contains('math add'));
    });
  });

  group('a rejected invocation shows that command own contract', () {
    test('a missing required option prints the usage of the command', () async {
      final result = await _run(['math', 'add', '--b', '7']);

      expect(result.exitCode, equals(ExitCode.validationFailed));
      expect(result.stderr, contains('--a'));
      expect(result.stderr, contains('First operand'));
      expect(result.stderr, contains('Usage: math add'));
    });

    test('--json keeps reporting a structured error, not help text', () async {
      final result = await _run(['math', 'add', '--b', '7', '--json']);

      expect(result.exitCode, equals(ExitCode.validationFailed));
      final error = jsonDecode(result.stderr) as Map<String, dynamic>;
      expect(error['error'], equals('VALIDATION_FAILED'));
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
