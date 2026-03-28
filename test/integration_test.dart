import 'dart:convert';
import 'dart:io';

import 'package:cli_router/cli_router.dart';
import 'package:modular_cli_sdk/modular_cli_sdk.dart';
import 'package:test/test.dart';

// ── Test doubles ────────────────────────────────────────────────────────────

class _GreetInput extends Input {
  final String name;
  _GreetInput({required this.name});

  factory _GreetInput.fromCliRequest(CliRequest req) =>
      _GreetInput(name: req.flagString('name') ?? 'World');

  @override
  Map<String, dynamic> toJson() => {'name': name};
}

class _GreetOutput extends Output {
  final String greeting;
  _GreetOutput({required this.greeting});

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
  Future<_GreetOutput> execute() async =>
      _GreetOutput(greeting: 'Hello, ${input.name}!');
}

class _RequiredInput extends Input {
  final String value;
  _RequiredInput({required this.value});

  factory _RequiredInput.fromCliRequest(CliRequest req) =>
      _RequiredInput(value: req.flagString('value') ?? '');

  @override
  Map<String, dynamic> toJson() => {'value': value};
}

class _EchoOutput extends Output {
  final String echo;
  _EchoOutput({required this.echo});

  @override
  Map<String, dynamic> toJson() => {'echo': echo};

  @override
  int get exitCode => ExitCode.ok;
}

class _ValidatingCommand implements Command<_RequiredInput, _EchoOutput> {
  @override
  final _RequiredInput input;
  _ValidatingCommand(this.input);

  @override
  String? validate() => input.value.isEmpty ? 'value is required' : null;

  @override
  Future<_EchoOutput> execute() async => _EchoOutput(echo: input.value);
}

class _FailingCommand implements Command<_GreetInput, _GreetOutput> {
  @override
  final _GreetInput input;
  _FailingCommand(this.input);

  @override
  String? validate() => null;

  @override
  Future<_GreetOutput> execute() async {
    throw CommandException(
      code: 'BROKEN',
      message: 'Intentional failure',
      exitCode: ExitCode.genericError,
    );
  }
}

// ── Memory sink (same pattern as cli_output_test) ───────────────────────────

class _MemorySink implements IOSink {
  final StringBuffer _buffer = StringBuffer();

  String get output => _buffer.toString();

  @override
  void write(Object? object) => _buffer.write(object);
  @override
  void writeln([Object? object = '']) {
    _buffer.write(object);
    _buffer.write('\n');
  }

  @override
  void writeAll(Iterable objects, [String separator = '']) =>
      _buffer.writeAll(objects, separator);
  @override
  void writeCharCode(int charCode) => _buffer.writeCharCode(charCode);
  @override
  void add(List<int> data) => _buffer.write(utf8.decode(data));
  @override
  void addError(Object error, [StackTrace? stackTrace]) {}
  @override
  Future addStream(Stream<List<int>> stream) async {
    await for (final data in stream) {
      add(data);
    }
  }

  @override
  Future flush() async {}
  @override
  Future close() async {}
  @override
  Future get done => Future.value();
  @override
  Encoding encoding = utf8;
}

// ── Helpers ─────────────────────────────────────────────────────────────────

ModularCli _buildTestCli() {
  final cli = ModularCli();

  cli.module('greetings', (m) {
    m.command<_GreetInput, _GreetOutput>(
      'hello',
      (req) => _GreetCommand(_GreetInput.fromCliRequest(req)),
      description: 'Say hello',
    );
    m.command<_GreetInput, _GreetOutput>(
      'fail',
      (req) => _FailingCommand(_GreetInput.fromCliRequest(req)),
      description: 'Always fails',
    );
  });

  cli.module('utils', (m) {
    m.command<_RequiredInput, _EchoOutput>(
      'echo',
      (req) => _ValidatingCommand(_RequiredInput.fromCliRequest(req)),
      description: 'Echo a value',
    );
  });

  return cli;
}

// ── Tests ───────────────────────────────────────────────────────────────────

void main() {
  late _MemorySink stdoutSink;
  late _MemorySink stderrSink;

  setUp(() {
    stdoutSink = _MemorySink();
    stderrSink = _MemorySink();
  });

  group('ModularCli integration', () {
    test('should run a successful command and produce text output', () async {
      final cli = _buildTestCli();
      final code = await cli.run(
        ['greetings', 'hello', '--name', 'Alice'],
        stdout: stdoutSink,
        stderr: stderrSink,
      );

      expect(code, ExitCode.ok);
      expect(stdoutSink.output, contains('Alice'));
    });

    test(
      'should run a successful command with --json and produce JSON',
      () async {
        final cli = _buildTestCli();
        final code = await cli.run(
          ['greetings', 'hello', '--name', 'Bob', '--json'],
          stdout: stdoutSink,
          stderr: stderrSink,
        );

        expect(code, ExitCode.ok);
        final parsed = jsonDecode(stdoutSink.output);
        expect(parsed['greeting'], 'Hello, Bob!');
      },
    );

    test('should run a failing command and produce structured error', () async {
      final cli = _buildTestCli();
      final code = await cli.run(
        ['greetings', 'fail', '--json'],
        stdout: stdoutSink,
        stderr: stderrSink,
      );

      expect(code, ExitCode.genericError);
      final parsed = jsonDecode(stderrSink.output);
      expect(parsed['error'], 'BROKEN');
    });

    test(
      'should run a command with validation error and return exit code 7',
      () async {
        final cli = _buildTestCli();
        final code = await cli.run(
          ['utils', 'echo'],
          stdout: stdoutSink,
          stderr: stderrSink,
        );

        expect(code, ExitCode.validationFailed);
        expect(stderrSink.output, contains('value is required'));
      },
    );

    test('should suppress messages with --quiet flag', () async {
      final cli = _buildTestCli();
      final code = await cli.run(
        ['greetings', 'hello', '--name', 'Eve', '--quiet'],
        stdout: stdoutSink,
        stderr: stderrSink,
      );

      // The command still succeeds — output is data, not a "message"
      expect(code, ExitCode.ok);
      // In text mode, writeObject is not suppressed by --quiet
      // (only writeMessage is). So we still see output.
      expect(stdoutSink.output, contains('Eve'));
    });

    test('should return exit code 64 on unknown command', () async {
      final cli = _buildTestCli();
      final code = await cli.run(
        ['nonexistent', 'command'],
        stdout: stdoutSink,
        stderr: stderrSink,
      );

      expect(code, ExitCode.invalidUsage);
    });

    test('should dispatch to correct module and command', () async {
      final cli = _buildTestCli();

      final greetCode = await cli.run(
        ['greetings', 'hello', '--name', 'X'],
        stdout: stdoutSink,
        stderr: stderrSink,
      );
      expect(greetCode, ExitCode.ok);
      expect(stdoutSink.output, contains('Hello, X!'));

      // Reset sinks
      stdoutSink = _MemorySink();
      stderrSink = _MemorySink();

      final echoCode = await cli.run(
        ['utils', 'echo', '--value', 'ping'],
        stdout: stdoutSink,
        stderr: stderrSink,
      );
      expect(echoCode, ExitCode.ok);
      expect(stdoutSink.output, contains('ping'));
    });

    test('should apply middleware in registration order', () async {
      final log = <String>[];

      final cli = ModularCli();
      cli.use(
        (next) => (req) async {
          log.add('A-before');
          final code = await next(req);
          log.add('A-after');
          return code;
        },
      );
      cli.use(
        (next) => (req) async {
          log.add('B-before');
          final code = await next(req);
          log.add('B-after');
          return code;
        },
      );

      cli.module('test', (m) {
        m.command<_GreetInput, _GreetOutput>(
          'cmd',
          (req) => _GreetCommand(_GreetInput(name: 'MW')),
          description: 'Test middleware order',
        );
      });

      await cli.run(['test', 'cmd'], stdout: stdoutSink, stderr: stderrSink);

      expect(log, ['A-before', 'B-before', 'B-after', 'A-after']);
    });
  });
}
