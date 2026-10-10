import 'dart:convert';
import 'dart:io';

import 'package:cli_router/cli_router.dart';
import 'package:modular_cli_sdk/modular_cli_sdk.dart';
import 'package:test/test.dart';

// Issue #54: a route registered at the root with a positional
// (`'<program>'`) printed `Usage: cx  [options] <program>`, with a double
// space: stripping the positionals out of the route leaves `''`, and the
// empty part was still joined. Empty parts are left out of the usage line.

class _ProgramInput extends Input {
  final String? program;
  _ProgramInput(this.program);

  static final contract = CliContract(
    options: [
      CliParam.string(
        'file',
        abbr: null,
        required: false,
        repeatable: false,
        defaultValue: null,
        description: 'Read the program from a file',
      ),
    ],
    positionals: [CliPositional.string('program', required: true)],
  );

  factory _ProgramInput.fromCliRequest(CliRequest req) =>
      _ProgramInput(req.param('program'));

  @override
  Map<String, dynamic> toJson() => {'program': program};
}

class _ProgramOutput extends Output {
  @override
  Map<String, dynamic> toJson() => {};

  @override
  int get exitCode => ExitCode.ok;
}

class _ProgramQuery implements Query<_ProgramInput, _ProgramOutput> {
  @override
  final _ProgramInput input;
  _ProgramQuery(this.input);

  @override
  String? validate() => null;

  @override
  Future<_ProgramOutput> execute() async => _ProgramOutput();
}

ModularCli _buildCli({String? name}) {
  final cli = ModularCli(
    suggestionDistance: 2,
    name: name,
    version: name == null ? null : '1.0.0',
  );
  cli.query<_ProgramInput, _ProgramOutput>(
    '<program>',
    (req) => _ProgramQuery(_ProgramInput.fromCliRequest(req)),
    globals: true,
    description: 'Run a program',
    contract: _ProgramInput.contract,
  );
  cli.query<_ProgramInput, _ProgramOutput>(
    'eval rpn [<program>]',
    (req) => _ProgramQuery(_ProgramInput.fromCliRequest(req)),
    globals: true,
    description: 'Evaluate RPN',
    contract: CliContract(
      options: _ProgramInput.contract.options,
      positionals: [CliPositional.string('program', required: false)],
    ),
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
  group('a root route with a positional (issue 54)', () {
    test('its contract help has a single space after the name', () async {
      final result = await _run(['abc', '--help'], cli: _buildCli(name: 'x'));

      expect(result.stdout, contains('Usage: x [options] <program>\n'));
      expect(result.stdout, isNot(contains('  [options]')));
    });

    test('the extra-argument error prints the same usage line', () async {
      final result = await _run(['nope', 'extra'], cli: _buildCli(name: 'x'));

      expect(result.stderr, contains('Usage: x [options] <program>\n'));
      expect(result.stderr, isNot(contains('  [options]')));
    });

    test('with no name there is no leading space', () async {
      final help = await _run(['abc', '--help'], cli: _buildCli());
      final error = await _run(['nope', 'extra'], cli: _buildCli());

      expect(help.stdout, contains('Usage: [options] <program>\n'));
      expect(help.stdout, isNot(contains('Usage:  ')));
      expect(error.stderr, contains('Usage: [options] <program>\n'));
    });

    test('a named route keeps its exact line', () async {
      final named = await _run([
        'eval',
        'rpn',
        '--help',
      ], cli: _buildCli(name: 'x'));
      final unnamed = await _run(['eval', 'rpn', '--help'], cli: _buildCli());

      expect(
        named.stdout,
        contains('Usage: x eval rpn [options] [<program>]\n'),
      );
      expect(
        unnamed.stdout,
        contains('Usage: eval rpn [options] [<program>]\n'),
      );
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
