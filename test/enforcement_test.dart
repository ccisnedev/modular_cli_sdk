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

  static final contract = CliContract(
    options: [
      CliParam.integer(
        'a',
        abbr: 'a',
        required: true,
        repeatable: false,
        description: 'First',
      ),
      CliParam.integer(
        'b',
        abbr: 'b',
        required: true,
        repeatable: false,
        description: 'Second',
      ),
    ],
  );

  factory _AddInput.fromCliRequest(CliRequest req) =>
      _AddInput(a: req.flagInt('a')!, b: req.flagInt('b')!);

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

class _AddCommand implements Query<_AddInput, _SumOutput> {
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

  static final contract = CliContract(
    options: [
      CliParam.string(
        'name',
        abbr: 'n',
        required: false,
        repeatable: false,
        defaultValue: const DeclaredDefault(
          'World',
          reason: 'the name used when nobody gave one',
        ),
      ),
      CliParam.enumeration(
        'format',
        required: false,
        repeatable: false,
        values: const ['text', 'shout'],
        defaultValue: const DeclaredDefault('text', reason: 'plain by default'),
      ),
    ],
  );

  factory _GreetInput.fromCliRequest(CliRequest req) => _GreetInput(
    name: req.flagString('name')!,
    format: req.flagString('format')!,
  );

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

class _GreetCommand implements Query<_GreetInput, _GreetOutput> {
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

  static final contract = CliContract(
    positionals: [CliPositional.integer('id', description: 'Id')],
  );

  factory _ShowInput.fromCliRequest(CliRequest req) =>
      _ShowInput(int.parse(req.param('id')!));

  @override
  Map<String, dynamic> toJson() => {'id': id};
}

class _ShowCommand implements Query<_ShowInput, _SumOutput> {
  @override
  final _ShowInput input;
  _ShowCommand(this.input);

  @override
  String? validate() => null;

  @override
  Future<_SumOutput> execute() async => _SumOutput(input.id);
}

// ── Declared command that takes NO options at all ────────────────────────────
//
// `CliContract.none` says "accepts no option whatsoever" explicitly — there is
// no undeclared escape hatch left in 0.6.0 for a command to leave unenforced,
// so what used to be "an undeclared command ignores an unknown flag" is no
// longer expressible: every command is enforced against its contract, and an
// empty contract is the strictest one there is.

class _InitInput extends Input {
  _InitInput();

  factory _InitInput.fromCliRequest(CliRequest req) => _InitInput();

  @override
  Map<String, dynamic> toJson() => {};
}

class _InitCommand implements Query<_InitInput, _SumOutput> {
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

  cli.query<_InitInput, _SumOutput>(
    'init',
    (req) => _InitCommand(_InitInput.fromCliRequest(req)),
    description: 'Takes no options',
    contract: CliContract.none,
  );

  cli.query<_GreetInput, _GreetOutput>(
    'greet',
    (req) => _GreetCommand(_GreetInput.fromCliRequest(req)),
    description: 'Greet someone',
    contract: _GreetInput.contract,
  );

  cli.query<_ShowInput, _SumOutput>(
    'show <id>',
    (req) => _ShowCommand(_ShowInput.fromCliRequest(req)),
    description: 'Show a record',
    contract: _ShowInput.contract,
  );

  cli.module('math', (m) {
    m.query<_AddInput, _SumOutput>(
      'add',
      (req) => _AddCommand(_AddInput.fromCliRequest(req)),
      description: 'Add two numbers',
      contract: _AddInput.contract,
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

  group('an undeclared option is rejected on every command', () {
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

  // "I accept no options" was inexpressible in 0.5.0: an absent `params:` was
  // the same as an empty list, so a zero-parameter command was indistinguish-
  // able from one whose arguments went unchecked entirely. That is precisely
  // the command most likely to be mis-invoked — `init --host foo` ran, doing
  // nothing of what the flag implied. `CliContract.none` is now that explicit,
  // enforced statement — and, in 0.6.0, the only kind of "no contract" there is.
  group('a command that declares an EMPTY contract accepts no option', () {
    test('a bare invocation runs', () async {
      final result = await _run(['init']);

      expect(result.exitCode, equals(ExitCode.ok));
    });

    test('any option is rejected with the contract it violated', () async {
      final result = await _run(['init', '--host', 'claude']);

      expect(result.exitCode, equals(ExitCode.validationFailed));
      // cli_router quotes the offending flag in its own message.
      expect(result.stderr, contains("unknown option '--host'"));
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
