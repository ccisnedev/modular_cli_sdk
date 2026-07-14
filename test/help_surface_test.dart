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

class _VersionInput extends Input {
  @override
  Map<String, dynamic> toJson() => {};
}

class _VersionOutput extends Output {
  @override
  Map<String, dynamic> toJson() => {'version': '1.0.0'};

  @override
  int get exitCode => ExitCode.ok;
}

class _VersionCommand implements Command<_VersionInput, _VersionOutput> {
  @override
  final _VersionInput input;
  _VersionCommand(this.input);

  @override
  String? validate() => null;

  @override
  Future<_VersionOutput> execute() async => _VersionOutput();
}

ModularCli _buildCli() {
  final cli = ModularCli();

  cli.command<_VersionInput, _VersionOutput>(
    'version',
    (req) => _VersionCommand(_VersionInput()),
    description: 'Print application version',
  );

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
  List<String> args, {
  ModularCli? cli,
}) async {
  final out = _TestSink();
  final err = _TestSink();
  final code = await (cli ?? _buildCli()).run(args, stdout: out, stderr: err);
  return (exitCode: code, stdout: out.toString(), stderr: err.toString());
}

void main() {
  group('every help entry point is a success on stdout', () {
    for (final args in [
      <String>[],
      ['help'],
      ['--help'],
      ['-h'],
    ]) {
      test(
        '${args.isEmpty ? "no args" : args.join(" ")} prints help, exit 0',
        () async {
          final result = await _run(args);

          expect(result.exitCode, equals(ExitCode.ok));
          expect(result.stderr, isEmpty);
          expect(result.stdout, contains('version'));
          expect(result.stdout, contains('math add'));
          expect(result.stdout, contains('Add two numbers'));
        },
      );
    }
  });

  group('the listing describes the registered commands', () {
    test('each command shows its description', () async {
      final result = await _run(['help']);

      expect(result.stdout, contains('Print application version'));
      expect(result.stdout, contains('Add two numbers'));
    });

    test('global options are documented once, not per command', () async {
      final result = await _run(['help']);

      expect(result.stdout, contains('Global options'));
      expect('--json'.allMatches(result.stdout).length, equals(1));
      expect(result.stdout, contains('--quiet'));
      expect(result.stdout, contains('-q'));
    });
  });

  group('developer intent wins', () {
    test(
      'a help command registered by the developer overrides the auto one',
      () async {
        final cli = ModularCli();
        cli.command<_VersionInput, _VersionOutput>(
          'help',
          (req) => _VersionCommand(_VersionInput()),
          description: 'My own help',
        );

        final result = await _run(['help'], cli: cli);

        expect(result.exitCode, equals(ExitCode.ok));
        expect(result.stdout, contains('1.0.0'));
        expect(result.stdout, isNot(contains('Global options')));
      },
    );
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
