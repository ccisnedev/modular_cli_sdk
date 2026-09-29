import 'dart:convert';

import 'package:cli_router/cli_router.dart';
import 'package:modular_cli_sdk/modular_cli_sdk.dart';
import 'package:test/test.dart';

import 'doubles.dart';

// cli_router 0.2.1 accepts options after operands (GNU permutation) by
// default and falls back to strict POSIX order when POSIXLY_CORRECT is set.
// ModularCli.run forwards [environment] to the router so that choice can be
// tested without touching the real process environment.

class _ShowInput extends Input {
  _ShowInput({required this.id, required this.verbose});
  final int id;
  final bool verbose;

  static final contract = CliContract(
    positionals: [CliPositional.integer('id', required: true)],
    options: [CliParam.flag('verbose', abbr: null, repeatable: false)],
  );

  factory _ShowInput.fromCliRequest(CliRequest req) => _ShowInput(
    id: req.positionalInt('id')!,
    verbose: req.flagBool('verbose'),
  );

  @override
  Map<String, dynamic> toJson() => {'id': id, 'verbose': verbose};
}

class _ShowOutput extends Output {
  _ShowOutput(this.id, this.verbose);
  final int id;
  final bool verbose;

  @override
  Map<String, dynamic> toJson() => {'id': id, 'verbose': verbose};

  @override
  int get exitCode => ExitCode.ok;
}

class _ShowQuery implements Query<_ShowInput, _ShowOutput> {
  _ShowQuery(this.input);

  @override
  final _ShowInput input;

  @override
  String? validate() => null;

  @override
  Future<_ShowOutput> execute() async => _ShowOutput(input.id, input.verbose);
}

ModularCli _buildCli() {
  final cli = ModularCli(suggestionDistance: 2);
  cli.query<_ShowInput, _ShowOutput>(
    'show <id>',
    (req) => _ShowQuery(_ShowInput.fromCliRequest(req)),
    globals: true,
    description: 'Show one record',
    contract: _ShowInput.contract,
  );
  return cli;
}

Future<({int exitCode, String stdout, String stderr})> _run(
  List<String> args,
  Map<String, String> environment,
) async {
  final out = MemorySink();
  final err = MemorySink();
  final code = await _buildCli().run(
    args,
    stdout: out,
    stderr: err,
    environment: environment,
  );
  return (exitCode: code, stdout: out.output, stderr: err.output);
}

void main() {
  group('option ordering', () {
    test('an option after the operand is accepted by default', () async {
      final result = await _run(['show', '--json', '1', '--verbose'], {});

      expect(result.exitCode, equals(ExitCode.ok));
      final data = jsonDecode(result.stdout) as Map<String, dynamic>;
      expect(data['verbose'], isTrue);
      expect(data['id'], equals(1));
    });

    test('POSIXLY_CORRECT rejects an option after the operand', () async {
      final result = await _run(
        ['show', '--json', '1', '--verbose'],
        {'POSIXLY_CORRECT': '1'},
      );

      expect(result.exitCode, equals(ExitCode.validationFailed));
      final envelope = jsonDecode(result.stderr) as Map<String, dynamic>;
      final error = envelope['error'] as Map<String, dynamic>;
      expect(error['id'], equals('misplaced-option'));
    });

    test('POSIXLY_CORRECT still accepts options before operands', () async {
      final result = await _run(
        ['show', '--json', '--verbose', '1'],
        {'POSIXLY_CORRECT': '1'},
      );

      expect(result.exitCode, equals(ExitCode.ok));
    });
  });
}
