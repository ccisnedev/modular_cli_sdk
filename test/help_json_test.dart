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
  group('help --json emits the contract catalog', () {
    test('is parseable JSON on stdout with exit 0', () async {
      final result = await _run(['help', '--json']);

      expect(result.exitCode, equals(ExitCode.ok));
      expect(result.stderr, isEmpty);
      expect(() => jsonDecode(result.stdout), returnsNormally);
    });

    test('describes every command with every parameter facet', () async {
      final result = await _run(['help', '--json']);
      final catalog = jsonDecode(result.stdout) as Map<String, dynamic>;

      final commands = catalog['commands'] as List;
      final add = commands.firstWhere((c) => c['route'] == 'math add');

      expect(add['module'], equals('math'));
      expect(add['description'], equals('Add two numbers'));

      final params = add['params'] as List;
      final a = params.firstWhere((p) => p['name'] == 'a');
      expect(a['kind'], equals('option'));
      expect(a['type'], equals('integer'));
      expect(a['aliases'], equals(['a']));
      expect(a['required'], isTrue);
      expect(a['description'], equals('First operand'));

      final b = params.firstWhere((p) => p['name'] == 'b');
      expect(b['required'], isFalse);
      expect(b['default'], equals(10));
    });

    test('documents the global options once, beside the commands', () async {
      final result = await _run(['help', '--json']);
      final catalog = jsonDecode(result.stdout) as Map<String, dynamic>;

      final names = (catalog['globalOptions'] as List)
          .map((o) => o['name'])
          .toList();

      expect(names, containsAll(['json', 'quiet', 'help']));
    });

    test('is the machine twin of the text listing', () async {
      final asJson = await _run(['help', '--json']);
      final asText = await _run(['help']);

      final routes =
          ((jsonDecode(asJson.stdout) as Map<String, dynamic>)['commands']
                  as List)
              .map((c) => c['route'] as String);

      for (final route in routes) {
        expect(asText.stdout, contains(route));
      }
    });
  });

  group('focused help --json', () {
    test('<command> --help --json emits only that command', () async {
      final result = await _run(['math', 'add', '--help', '--json']);
      final contract = jsonDecode(result.stdout) as Map<String, dynamic>;

      expect(result.exitCode, equals(ExitCode.ok));
      expect(contract['route'], equals('math add'));
      expect((contract['params'] as List).length, equals(2));
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
