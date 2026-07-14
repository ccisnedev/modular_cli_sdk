import 'dart:convert';
import 'dart:io';

import 'package:cli_router/cli_router.dart';
import 'package:modular_cli_sdk/modular_cli_sdk.dart';
import 'package:test/test.dart';

// ── Declared command: math add --a <int> --b <int> ───────────────────────────

class _AddInput extends Input {
  final int a;
  final int b;
  _AddInput({required this.a, required this.b});

  static final params = [
    CliParam.integer('a', abbr: 'a', required: true, description: 'First'),
    CliParam.integer('b', abbr: 'b', required: true, description: 'Second'),
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

// ── Declared command: greet --name <string> (default) --format <allowed> ─────

class _GreetInput extends Input {
  final String name;
  final String format;
  _GreetInput({required this.name, required this.format});

  static final params = [
    CliParam.string('name', abbr: 'n', defaultValue: 'World'),
    CliParam.string('format', allowed: ['text', 'shout']),
  ];

  factory _GreetInput.fromCliRequest(CliRequest req) => _GreetInput(
    name: req.flagString('name')!,
    format: req.flagString('format') ?? 'text',
  );

  @override
  List<CliParam> get schemaFields => params;

  @override
  Map<String, dynamic> toJson() => {'name': name, 'format': format};
}

class _GreetOutput extends Output {
  final String greeting;
  _GreetOutput(this.greeting);

  @override
  Map<String, dynamic> toJson() => {'greeting': greeting};

  @override
  int get exitCode => ExitCode.ok;
}

class _GreetCommand implements Command<_GreetInput, _GreetOutput> {
  @override
  final _GreetInput input;
  _GreetCommand(this.input);

  @override
  String? validate() => null;

  @override
  Future<_GreetOutput> execute() async {
    final greeting = 'Hello, ${input.name}!';
    return _GreetOutput(
      input.format == 'shout' ? greeting.toUpperCase() : greeting,
    );
  }
}

// ── Declared command with a typed positional: show <id> ──────────────────────

class _ShowInput extends Input {
  final int id;
  _ShowInput(this.id);

  static final params = [
    CliParam.positional('id', type: CliParamType.integer, description: 'Id'),
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

// ── Undeclared command (backward compatibility) ──────────────────────────────

class _LegacyInput extends Input {
  final int a;
  _LegacyInput(this.a);

  factory _LegacyInput.fromCliRequest(CliRequest req) =>
      _LegacyInput(req.flagInt('a') ?? 0);

  @override
  Map<String, dynamic> toJson() => {'a': a};
}

class _LegacyCommand implements Command<_LegacyInput, _SumOutput> {
  @override
  final _LegacyInput input;
  _LegacyCommand(this.input);

  @override
  String? validate() => null;

  @override
  Future<_SumOutput> execute() async => _SumOutput(input.a);
}

// ── Declared command that takes NO options at all ────────────────────────────
//
// Distinct from _LegacyInput: that one declares nothing (undeclared, not
// enforced). This one declares its contract and the contract is *empty* — it
// accepts no option whatsoever, and anything passed is an error.

class _InitInput extends Input {
  _InitInput();

  static const List<CliParam> params = [];

  factory _InitInput.fromCliRequest(CliRequest req) => _InitInput();

  @override
  List<CliParam> get schemaFields => params;

  @override
  Map<String, dynamic> toJson() => {};
}

class _InitCommand implements Command<_InitInput, _SumOutput> {
  @override
  final _InitInput input;
  _InitCommand(this.input);

  @override
  String? validate() => null;

  @override
  Future<_SumOutput> execute() async => _SumOutput(0);
}

ModularCli _buildCli() {
  final cli = ModularCli();

  cli.command<_InitInput, _SumOutput>(
    'init',
    (req) => _InitCommand(_InitInput.fromCliRequest(req)),
    description: 'Takes no options',
    params: _InitInput.params,
  );

  cli.command<_GreetInput, _GreetOutput>(
    'greet',
    (req) => _GreetCommand(_GreetInput.fromCliRequest(req)),
    description: 'Greet someone',
    params: _GreetInput.params,
  );

  cli.command<_ShowInput, _SumOutput>(
    'show <id>',
    (req) => _ShowCommand(_ShowInput.fromCliRequest(req)),
    description: 'Show a record',
    params: _ShowInput.params,
  );

  cli.command<_LegacyInput, _SumOutput>(
    'legacy',
    (req) => _LegacyCommand(_LegacyInput.fromCliRequest(req)),
    description: 'Declares no contract',
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
  List<String> args,
) async {
  final out = _TestSink();
  final err = _TestSink();
  final code = await _buildCli().run(args, stdout: out, stderr: err);
  return (exitCode: code, stdout: out.toString(), stderr: err.toString());
}

void main() {
  group('a missing required parameter is rejected', () {
    test('math add --b 7 fails instead of defaulting --a to zero', () async {
      final result = await _run(['math', 'add', '--b', '7']);

      expect(result.exitCode, equals(ExitCode.validationFailed));
      expect(result.stderr, contains('--a'));
      expect(result.stdout, isEmpty);
    });
  });

  group('a value that does not honour its declared type is rejected', () {
    test('math add --a abc fails instead of coercing to zero', () async {
      final result = await _run(['math', 'add', '--a', 'abc', '--b', '7']);

      expect(result.exitCode, equals(ExitCode.validationFailed));
      expect(result.stderr, contains('--a'));
      expect(result.stderr, contains('integer'));
    });

    test('a positional is coerced to its declared type', () async {
      final valid = await _run(['show', '42']);
      expect(valid.exitCode, equals(ExitCode.ok));
      expect(valid.stdout, contains('42'));

      final invalid = await _run(['show', 'abc']);
      expect(invalid.exitCode, equals(ExitCode.validationFailed));
      expect(invalid.stderr, contains('<id>'));
    });
  });

  group('an undeclared parameter is rejected', () {
    test('math add --typo-flag x fails instead of being ignored', () async {
      final result = await _run([
        'math',
        'add',
        '--a',
        '3',
        '--b',
        '7',
        '--typo-flag',
        'x',
      ]);

      expect(result.exitCode, equals(ExitCode.validationFailed));
      expect(result.stderr, contains('typo-flag'));
    });

    test('the global flags are always accepted', () async {
      final result = await _run(['math', 'add', '--a', '3', '--b', '7', '-q']);

      expect(result.exitCode, equals(ExitCode.ok));
    });
  });

  group('the declaration governs how a value is read', () {
    test('an absent optional parameter takes its declared default', () async {
      final result = await _run(['greet']);

      expect(result.exitCode, equals(ExitCode.ok));
      expect(result.stdout, contains('Hello, World!'));
    });

    test('an abbr resolves to its long name', () async {
      final result = await _run(['greet', '-n', 'Ada']);

      expect(result.exitCode, equals(ExitCode.ok));
      expect(result.stdout, contains('Hello, Ada!'));
    });

    test('a value outside the allowed set is rejected', () async {
      final result = await _run(['greet', '--format', 'xml']);

      expect(result.exitCode, equals(ExitCode.validationFailed));
      expect(result.stderr, contains('text'));
    });

    test('a value inside the allowed set runs', () async {
      final result = await _run([
        'greet',
        '--name',
        'Ada',
        '--format',
        'shout',
      ]);

      expect(result.exitCode, equals(ExitCode.ok));
      expect(result.stdout, contains('HELLO, ADA!'));
    });
  });

  group('a command that declares no contract is not enforced', () {
    test('legacy keeps its imperative defaulting', () async {
      final result = await _run(['legacy']);

      expect(result.exitCode, equals(ExitCode.ok));
      expect(result.stdout, contains('0'));
    });

    test('legacy still ignores an unknown flag', () async {
      final result = await _run(['legacy', '--whatever', 'x']);

      expect(result.exitCode, equals(ExitCode.ok));
    });
  });

  // "I accept no options" was inexpressible: `params: const []` is the same
  // value as the default, so a zero-parameter command was indistinguishable
  // from an undeclared one and its arguments went unchecked. That is precisely
  // the command most likely to be mis-invoked — `init --host foo` ran, doing
  // nothing of what the flag implied.
  group('a command that declares an EMPTY contract accepts no option', () {
    test('a bare invocation runs', () async {
      final result = await _run(['init']);

      expect(result.exitCode, equals(ExitCode.ok));
    });

    test('any option is rejected with the contract it violated', () async {
      final result = await _run(['init', '--host', 'claude']);

      expect(result.exitCode, equals(ExitCode.validationFailed));
      expect(result.stderr, contains('unknown option --host'));
    });

    test('it is still described in the help', () async {
      final result = await _run(['help']);

      expect(result.stdout, contains('init'));
      expect(result.stdout, contains('Takes no options'));
    });
  });

  group('a rejection is reported through the active output mode', () {
    test('--json reports the validation failure as structured JSON', () async {
      final result = await _run(['math', 'add', '--b', '7', '--json']);

      expect(result.exitCode, equals(ExitCode.validationFailed));
      final error = jsonDecode(result.stderr) as Map<String, dynamic>;
      expect(error['error'], equals('VALIDATION_FAILED'));
      expect(error['details'], containsPair('parameter', 'a'));
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
