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
    CliParam.integer('b', defaultValue: 10, description: 'Second operand'),
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

class _ShowInput extends Input {
  final int id;
  _ShowInput(this.id);

  static final params = [
    CliParam.positional(
      'id',
      type: CliParamType.integer,
      description: 'Record id',
    ),
  ];

  factory _ShowInput.fromCliRequest(CliRequest req) =>
      _ShowInput(int.parse(req.param('id')!));

  @override
  List<CliParam> get schemaFields => params;

  @override
  Map<String, dynamic> toJson() => {'id': id};
}

class _ShowCommand implements Command<_ShowInput, _SumOutput> {
  @override
  final _ShowInput input;
  _ShowCommand(this.input);

  @override
  String? validate() => null;

  @override
  Future<_SumOutput> execute() async => _SumOutput(input.id);
}

ModularCli _buildCli() {
  final cli = ModularCli();

  cli.command<_ShowInput, _SumOutput>(
    'show <id>',
    (req) => _ShowCommand(_ShowInput.fromCliRequest(req)),
    description: 'Show a record',
    params: _ShowInput.params,
  );

  cli.module('math', (m) {
    m.command<_AddInput, _SumOutput>(
      'add',
      (req) => _AddCommand(_AddInput.fromCliRequest(req)),
      description: 'Add two numbers',
      params: _AddInput.params,
    );
    m.command<_AddInput, _SumOutput>(
      'multiply',
      (req) => _AddCommand(_AddInput.fromCliRequest(req)),
      description: 'Multiply two numbers',
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
  group('<command> --help shows only that command', () {
    test('renders its full contract on stdout, exit 0', () async {
      final result = await _run(['math', 'add', '--help']);

      expect(result.exitCode, equals(ExitCode.ok));
      expect(result.stderr, isEmpty);
      expect(result.stdout, contains('math add'));
      expect(result.stdout, contains('First operand'));
      expect(result.stdout, contains('required'));
      expect(result.stdout, contains('default: 10'));
      expect(result.stdout, contains('-a'));
      expect(
        result.stdout,
        isNot(contains('Multiply two numbers')),
        reason: 'focused help must not list the rest of the CLI',
      );
    });

    test('help wins over the enforcement of a missing parameter', () async {
      final result = await _run(['math', 'add', '--help']);

      expect(
        result.exitCode,
        equals(ExitCode.ok),
        reason: '--help on an incomplete invocation must help, not fail',
      );
    });

    test('a positional is shown as a required argument', () async {
      final result = await _run(['show', '1', '--help']);

      expect(result.exitCode, equals(ExitCode.ok));
      expect(result.stdout, contains('<id>'));
      expect(result.stdout, contains('Record id'));
      expect(result.stdout, contains('required'));
    });
  });

  group('<module> --help shows the whole module', () {
    test('lists every command under the module with its contract', () async {
      final result = await _run(['math', '--help']);

      expect(result.exitCode, equals(ExitCode.ok));
      expect(result.stderr, isEmpty);
      expect(result.stdout, contains('math add'));
      expect(result.stdout, contains('math multiply'));
      expect(result.stdout, contains('First operand'));
      expect(
        result.stdout,
        isNot(contains('Show a record')),
        reason: 'a module view must not leak the root commands',
      );
    });
  });

  group('an invalid command with --help is still an error', () {
    test('bogus --help goes to stderr with exit 64', () async {
      final result = await _run(['bogus', '--help']);

      expect(result.exitCode, equals(ExitCode.invalidUsage));
      expect(result.stdout, isEmpty);
      expect(result.stderr, isNotEmpty);
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
