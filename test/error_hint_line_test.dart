import 'dart:convert';

import 'package:modular_cli_sdk/modular_cli_sdk.dart';
import 'package:test/test.dart';

import 'doubles.dart';

// Issue #52: an error with neither a contract nor completions prints one
// hint line, not the whole catalog.

class _NoInput extends Input {
  @override
  Map<String, dynamic> toJson() => {};
}

class _TextOutput extends Output {
  _TextOutput(this.text);
  final String text;

  @override
  Map<String, dynamic> toJson() => {'text': text};

  @override
  String? toText() => text;

  @override
  int get exitCode => ExitCode.ok;
}

class _TextQuery implements Query<_NoInput, _TextOutput> {
  _TextQuery(this.text);
  final String text;

  @override
  final _NoInput input = _NoInput();

  @override
  String? validate() => null;

  @override
  Future<_TextOutput> execute() async => _TextOutput(text);
}

const _epilog = 'Examples:\n  x eval rpn "1 2 +"';

ModularCli _cli({bool named = true, bool shortcut = true, String? epilog}) {
  final cli = named
      ? ModularCli(
          suggestionDistance: 2,
          name: 'x',
          version: '1.2.3',
          helpEpilog: epilog,
        )
      : ModularCli(suggestionDistance: 2, helpEpilog: epilog);
  cli.module('eval', (m) {
    m.query<_NoInput, _TextOutput>(
      'rpn [<program>]',
      (req) => _TextQuery('rpn'),
      globals: true,
      description: 'Evaluate an RPN program',
      contract: CliContract(
        positionals: [CliPositional.string('program', required: false)],
      ),
    );
    m.query<_NoInput, _TextOutput>(
      'infix',
      (req) => _TextQuery('infix'),
      globals: true,
      description: 'Evaluate an infix expression',
      contract: CliContract.none,
    );
  });
  cli.module('math', (m) {
    m.query<_NoInput, _TextOutput>(
      'add',
      (req) => _TextQuery('add'),
      globals: true,
      description: 'Add numbers',
      contract: CliContract.none,
    );
  });
  cli.query<_NoInput, _TextOutput>(
    '',
    (req) => _TextQuery('root'),
    globals: true,
    description: 'The root query',
    contract: CliContract.none,
  );
  if (shortcut) {
    cli.shortcut(
      '<program>',
      target: 'eval rpn',
      globals: true,
      description: 'Evaluate a program',
      contract: CliContract.none,
    );
  }
  return cli;
}

/// CLI A mirrors `cx`: a root query and a root shortcut. CLI B has the root
/// query only.
ModularCli _cliA({bool named = true, String? epilog}) =>
    _cli(named: named, epilog: epilog);
ModularCli _cliB({String? epilog}) => _cli(shortcut: false, epilog: epilog);

Future<({int exitCode, String stdout, String stderr})> _run(
  ModularCli cli,
  List<String> args,
) async {
  final out = MemorySink();
  final err = MemorySink();
  final code = await cli.run(args, stdout: out, stderr: err);
  return (exitCode: code, stdout: out.output, stderr: err.output);
}

void main() {
  const hint = 'Run "x --help" to see every command.';

  group('no contract, no completions: one hint line', () {
    // On CLI A a bare word is the shortcut's <program>, so the unknown
    // command with no completion is exercised on CLI B.
    final cases =
        <(String, ModularCli Function({String? epilog}), List<String>)>[
          ('A', ({String? epilog}) => _cliA(epilog: epilog), ['--bogus']),
          ('B', ({String? epilog}) => _cliB(epilog: epilog), ['nope']),
        ];
    for (final (label, make, args) in cases) {
      test('CLI $label: x ${args.join(' ')}', () async {
        final r = await _run(make(), args);
        final lines = r.stderr.split('\n');
        expect(lines.first, startsWith('Error: '));
        expect(lines, contains(''));
        expect(r.stderr, endsWith('\n\n$hint\n'));
        // Error line (+ optional details), blank line, hint, nothing else.
        final blank = lines.indexOf('');
        expect(lines.sublist(blank), ['', hint, '']);
        expect(r.stderr, isNot(contains('Usage:')));
        expect(r.stderr, isNot(contains('Queries:')));
        expect(r.stdout, isEmpty);
      });

      test(
        'CLI $label: x ${args.join(' ')} never carries the epilog',
        () async {
          final r = await _run(make(epilog: _epilog), args);
          expect(r.stderr, isNot(contains('Examples:')));
          expect(r.stderr, endsWith('\n\n$hint\n'));
        },
      );

      test('CLI $label: x --json ${args.join(' ')} is unchanged', () async {
        final r = await _run(make(), ['--json', ...args]);
        final decoded = jsonDecode(r.stderr.trim()) as Map<String, dynamic>;
        final error = decoded['error'] as Map<String, dynamic>;
        expect(error.keys, isNot(contains('hint')));
        expect(r.stderr, isNot(contains('see every command')));
        expect(r.stderr.trim().split('\n'), hasLength(1));
      });
    }

    test('a CLI without a name says "with --help"', () async {
      final r = await _run(_cliA(named: false), ['--bogus']);
      expect(r.stderr, endsWith('\n\nRun with --help to see every command.\n'));
      expect(r.stderr, isNot(contains('Usage:')));
    });
  });

  group('the other two contexts are untouched', () {
    test('a prefix with completions prints the narrowed catalog', () async {
      final r = await _run(_cliA(epilog: _epilog), ['eval']);
      expect(r.stderr, contains('Usage: x'));
      expect(r.stderr, contains('eval rpn'));
      expect(r.stderr, contains('eval infix'));
      expect(r.stderr, isNot(contains('math add')));
      expect(r.stderr, isNot(contains('see every command')));
      expect(r.stderr, isNot(contains('Examples:')));
    });

    test(
      'CLI B: an option error at the root prints the root contract',
      () async {
        final r = await _run(_cliB(epilog: _epilog), ['--bogus']);
        expect(r.stderr, contains('Usage: x'));
        expect(r.stderr, contains('The root query'));
        expect(r.stderr, isNot(contains('see every command')));
        expect(r.stderr, isNot(contains('Examples:')));
      },
    );

    test('an option error on a resolved route prints its contract', () async {
      final r = await _run(_cliA(epilog: _epilog), ['math', 'add', '--bogus']);
      expect(r.stderr, contains('math add'));
      expect(r.stderr, isNot(contains('see every command')));
      expect(r.stderr, isNot(contains('eval rpn')));
      expect(r.stderr, isNot(contains('Examples:')));
    });
  });
}
