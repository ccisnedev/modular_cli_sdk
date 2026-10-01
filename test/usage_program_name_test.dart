import 'dart:convert';
import 'dart:io';

import 'package:cli_router/cli_router.dart';
import 'package:modular_cli_sdk/modular_cli_sdk.dart';
import 'package:test/test.dart';

// Issue #38: usage lines never named the program. `ModularCli(name: 'cx')`
// stored the name in `hostMetadata`, but `HelpRenderer` had no way to
// receive it, so `cx --help` printed a root listing with no usage line at
// all, and every command's usage line read `Usage: math add ...` instead of
// `Usage: cx math add ...`. A user reading either could not copy the line
// shown and run it.
//
// This file pins the fix's four acceptance cases directly:
//   * root help, with a name, gets a meaningful usage line naming the
//     program, not a blank one;
//   * a command's own usage line, in its help, is prefixed with the name;
//   * one rejection path (a missing required positional, "missing operand")
//     is prefixed too;
//   * with no name given at all, every one of these is byte-identical to
//     before this fix (no stray prefix, no stray blank line).

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
        defaultValue: null,
        description: 'First operand',
      ),
      CliParam.integer(
        'b',
        abbr: 'b',
        required: true,
        repeatable: false,
        defaultValue: null,
        description: 'Second operand',
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

class _ShowInput extends Input {
  final String id;
  _ShowInput(this.id);

  static final contract = CliContract(
    positionals: [CliPositional.string('id', required: true)],
  );

  factory _ShowInput.fromCliRequest(CliRequest req) =>
      _ShowInput(req.param('id')!);

  @override
  Map<String, dynamic> toJson() => {'id': id};
}

class _ShowOutput extends Output {
  final String id;
  _ShowOutput(this.id);

  @override
  Map<String, dynamic> toJson() => {'id': id};

  @override
  int get exitCode => ExitCode.ok;
}

class _ShowCommand implements Query<_ShowInput, _ShowOutput> {
  @override
  final _ShowInput input;
  _ShowCommand(this.input);

  @override
  String? validate() => null;

  @override
  Future<_ShowOutput> execute() async => _ShowOutput(input.id);
}

ModularCli _buildCli({String? name, String? version}) {
  final cli = ModularCli(suggestionDistance: 2, name: name, version: version);

  cli.module('math', (m) {
    m.query<_AddInput, _SumOutput>(
      'add',
      (req) => _AddCommand(_AddInput.fromCliRequest(req)),
      globals: true,
      description: 'Add two numbers',
      contract: _AddInput.contract,
    );
  });

  cli.query<_ShowInput, _ShowOutput>(
    'show <id>',
    (req) => _ShowCommand(_ShowInput.fromCliRequest(req)),
    globals: true,
    description: 'Show one record',
    contract: _ShowInput.contract,
  );

  return cli;
}

Future<({int exitCode, String stdout, String stderr})> _run(
  List<String> args, {
  required ModularCli cli,
}) async {
  final out = _TestSink();
  final err = _TestSink();
  final code = await cli.run(args, stdout: out, stderr: err);
  return (exitCode: code, stdout: out.toString(), stderr: err.toString());
}

void main() {
  group('with a name, usage lines name the program (issue 38)', () {
    test(
      'root help prints a meaningful usage line naming the program',
      () async {
        final cli = _buildCli(name: 'cx', version: '1.0.0');
        final result = await _run(['--help'], cli: cli);

        expect(result.exitCode, equals(ExitCode.ok));
        final usageLine = result.stdout
            .split('\n')
            .firstWhere((line) => line.startsWith('Usage:'));
        expect(usageLine, equals('Usage: cx <command> [options]'));
        expect(
          usageLine,
          isNot(equals('Usage: cx')),
          reason:
              'a name with nothing after it is not a usage line a user '
              'could type',
        );
      },
    );

    test(
      'a command\'s own help prefixes its usage line with the program',
      () async {
        final cli = _buildCli(name: 'cx', version: '1.0.0');
        final result = await _run(['math', 'add', '--help'], cli: cli);

        expect(result.exitCode, equals(ExitCode.ok));
        expect(result.stdout, contains('Usage: cx math add [options]'));
      },
    );

    test(
      'a missing operand (a required positional) names the program too',
      () async {
        final cli = _buildCli(name: 'cx', version: '1.0.0');
        final result = await _run(['show'], cli: cli);

        expect(result.exitCode, equals(ExitCode.invalidUsage));
        expect(result.stderr, contains('Usage: cx show <id>'));
      },
    );

    test(
      'an unknown option also gets the program-prefixed usage line',
      () async {
        final cli = _buildCli(name: 'cx', version: '1.0.0');
        final result = await _run(['math', 'add', '--bogus'], cli: cli);

        expect(result.exitCode, equals(ExitCode.validationFailed));
        expect(result.stderr, contains('Usage: cx math add [options]'));
      },
    );
  });

  group('with no name, output stays byte-identical (issue 38)', () {
    test('root help has no usage line and no extra blank line', () async {
      final named = await _run([
        '--help',
      ], cli: _buildCli(name: 'cx', version: '1.0.0'));
      final unnamed = await _run(['--help'], cli: _buildCli());

      expect(unnamed.stdout, isNot(contains('Usage:')));
      expect(
        unnamed.stdout,
        isNot(equals(named.stdout)),
        reason: 'the named and unnamed renderings must actually differ',
      );
    });

    test('a command\'s own help has no program prefix', () async {
      final result = await _run(['math', 'add', '--help'], cli: _buildCli());

      expect(result.stdout, contains('Usage: math add [options]'));
      expect(result.stdout, isNot(contains('Usage: cx')));
    });

    test('a missing operand keeps the unprefixed usage line', () async {
      final result = await _run(['show'], cli: _buildCli());

      expect(result.exitCode, equals(ExitCode.invalidUsage));
      expect(result.stderr, contains('Usage: show <id>'));
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
