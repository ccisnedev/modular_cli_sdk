import 'dart:convert';

import 'package:modular_cli_sdk/modular_cli_sdk.dart';
import 'package:test/test.dart';

import 'doubles.dart';

// Issue #47: at the root, `--help` / `-h` answer as the `help` query and
// `--version` answers as the `version` query. A route's own `--help` is
// unchanged, and so is the precedence of a badly typed value over `--help`.

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

ModularCli _cli({
  bool withVersion = true,
  bool rootShortcut = false,
  bool rootRoute = false,
}) {
  final cli = ModularCli(suggestionDistance: 2, name: 'x', version: '1.2.3');
  cli.module('eval', (m) {
    m.query<_NoInput, _TextOutput>(
      'rpn [<program>]',
      (req) => _TextQuery('ran ${req.param('program')}'),
      globals: true,
      description: 'Evaluate an RPN program',
      contract: CliContract(
        positionals: [CliPositional.string('program', required: false)],
        options: [
          CliParam.integer(
            'n',
            abbr: null,
            required: false,
            repeatable: false,
            defaultValue: null,
            description: 'A count',
          ),
        ],
      ),
    );
  });
  if (withVersion) {
    cli.query<_NoInput, _TextOutput>(
      'version',
      (req) => _TextQuery('x 1.2.3'),
      globals: true,
      description: 'Print version info',
      contract: CliContract.none,
    );
  }
  if (rootShortcut) {
    cli.shortcut(
      '<program>',
      target: 'eval rpn',
      globals: true,
      description: 'Evaluate a program',
      contract: CliContract.none,
    );
  }
  if (rootRoute) {
    cli.query<_NoInput, _TextOutput>(
      '',
      (req) => _TextQuery('dashboard'),
      globals: true,
      description: 'The dashboard',
      contract: CliContract.none,
    );
  }
  return cli;
}

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
  group('root --help is the catalog', () {
    test('--help, -h and help print the same text and exit 0', () async {
      final help = await _run(_cli(), ['help']);
      final long = await _run(_cli(), ['--help']);
      final short = await _run(_cli(), ['-h']);

      expect(help.exitCode, ExitCode.ok);
      expect(long.exitCode, ExitCode.ok);
      expect(short.exitCode, ExitCode.ok);
      expect(long.stdout, help.stdout);
      expect(short.stdout, help.stdout);
      expect(long.stdout, contains('Commands:'));
      expect(long.stdout, contains('eval rpn'));
    });

    test('their --json outputs are equal', () async {
      final help = await _run(_cli(), ['help', '--json']);
      final long = await _run(_cli(), ['--help', '--json']);
      final short = await _run(_cli(), ['-h', '--json']);
      final reversed = await _run(_cli(), ['--json', '--help']);

      expect(long.exitCode, ExitCode.ok);
      expect(jsonDecode(long.stdout), jsonDecode(help.stdout));
      expect(jsonDecode(short.stdout), jsonDecode(help.stdout));
      expect(jsonDecode(reversed.stdout), jsonDecode(help.stdout));
      expect((jsonDecode(long.stdout) as Map).containsKey('commands'), isTrue);
    });

    test('--quiet alongside --help still answers as help', () async {
      final help = await _run(_cli(), ['help', '--quiet']);
      final long = await _run(_cli(), ['--quiet', '--help']);
      expect(long.exitCode, ExitCode.ok);
      expect(long.stdout, help.stdout);
    });

    test('a route --help keeps the route contract', () async {
      final result = await _run(_cli(), ['eval', 'rpn', '--help']);
      expect(result.exitCode, ExitCode.ok);
      expect(result.stdout, startsWith('Usage: x eval rpn'));
      expect(result.stdout, contains('Evaluate an RPN program'));
      expect(result.stdout, isNot(contains('Commands:')));

      final short = await _run(_cli(), ['eval', 'rpn', '-h']);
      expect(short.stdout, result.stdout);
    });

    test('a badly typed supplied value still beats --help', () async {
      final result = await _run(_cli(), [
        'eval',
        'rpn',
        '--n',
        'abc',
        '--help',
      ]);
      expect(result.exitCode, isNot(ExitCode.ok));
      expect(result.stderr, contains('--n'));
      expect(result.stdout, isNot(contains('Commands:')));
    });

    test('a CLI with a root route still gets the catalog', () async {
      final help = await _run(_cli(rootRoute: true), ['help']);
      for (final args in [
        ['--help'],
        ['-h'],
        ['--quiet', '--help'],
      ]) {
        final result = await _run(_cli(rootRoute: true), args);
        expect(result.exitCode, ExitCode.ok, reason: '$args');
        expect(result.stdout, contains('Commands:'), reason: '$args');
        if (!args.contains('--quiet')) {
          expect(result.stdout, help.stdout, reason: '$args');
        }
      }
      final quiet = await _run(_cli(rootRoute: true), ['help', '--quiet']);
      final quietHelp = await _run(_cli(rootRoute: true), ['-q', '--help']);
      expect(quietHelp.stdout, quiet.stdout);

      final helpJson = await _run(_cli(rootRoute: true), ['help', '--json']);
      final flagJson = await _run(_cli(rootRoute: true), ['--help', '--json']);
      expect(jsonDecode(flagJson.stdout), jsonDecode(helpJson.stdout));
    });

    test('a bare invocation still runs the root route', () async {
      final result = await _run(_cli(rootRoute: true), []);
      expect(result.stdout, contains('dashboard'));
    });
  });

  group('root --version is the version query', () {
    test('--version and version print the same text and exit 0', () async {
      final query = await _run(_cli(), ['version']);
      final flag = await _run(_cli(), ['--version']);

      expect(flag.exitCode, ExitCode.ok);
      expect(query.exitCode, ExitCode.ok);
      expect(flag.stdout, query.stdout);
      expect(flag.stdout, contains('1.2.3'));
    });

    test('their --json outputs are equal', () async {
      final query = await _run(_cli(), ['version', '--json']);
      final flag = await _run(_cli(), ['--version', '--json']);

      expect(flag.exitCode, ExitCode.ok);
      expect(jsonDecode(flag.stdout), jsonDecode(query.stdout));
    });

    test('-v stays free for the CLI to use', () async {
      final cli = ModularCli(
        suggestionDistance: 2,
        name: 'x',
        version: '1.2.3',
      );
      cli.query<_NoInput, _TextOutput>(
        'run',
        (req) => _TextQuery('verbose=${req.flagBool('verbose')}'),
        globals: true,
        contract: CliContract(
          options: [
            CliParam.flag(
              'verbose',
              abbr: 'v',
              repeatable: false,
              description: 'Talk more',
            ),
          ],
        ),
      );
      final result = await _run(cli, ['run', '-v']);
      expect(result.exitCode, ExitCode.ok);
      expect(result.stdout, contains('verbose=true'));
    });

    test('a CLI with no version route keeps the unknown option', () async {
      final result = await _run(_cli(withVersion: false), ['--version']);
      expect(result.exitCode, ExitCode.validationFailed);
      expect(result.stderr, contains('--version'));
    });

    test('a route --version is not the root --version', () async {
      final result = await _run(_cli(), ['eval', 'rpn', '--version']);
      expect(result.exitCode, ExitCode.validationFailed);
    });
  });

  group('the catalog shows root shortcuts', () {
    test('a root shortcut appears with its target and a usage line', () async {
      final result = await _run(_cli(rootShortcut: true), ['--help']);

      expect(result.exitCode, ExitCode.ok);
      expect(result.stdout, contains('Usage: x <command> [options]'));
      expect(result.stdout, contains('       x <program>'));
      expect(result.stdout, contains('Shortcuts:'));
      expect(result.stdout, contains('same as: eval rpn'));
    });

    test('--json carries the shortcut with its target', () async {
      final result = await _run(_cli(rootShortcut: true), ['--help', '--json']);
      final json = jsonDecode(result.stdout) as Map<String, dynamic>;
      final shortcuts = json['shortcuts'] as List;
      expect(shortcuts, hasLength(1));
      expect((shortcuts.single as Map)['route'], '<program>');
      expect((shortcuts.single as Map)['target'], 'eval rpn');
    });

    test('without a root shortcut the catalog is unchanged', () async {
      final result = await _run(_cli(), ['help']);
      expect(result.stdout, isNot(contains('Shortcuts:')));
      final json = jsonDecode((await _run(_cli(), ['help', '--json'])).stdout);
      expect((json as Map).containsKey('shortcuts'), isFalse);
    });
  });

  group('--version is reserved at the root', () {
    ModularCli declaring(String route) {
      final cli = ModularCli(
        suggestionDistance: 2,
        name: 'x',
        version: '1.2.3',
      );
      cli.query<_NoInput, _TextOutput>(
        route,
        (req) => _TextQuery('hi'),
        globals: true,
        contract: CliContract(
          options: [
            CliParam.string(
              'version',
              abbr: null,
              required: false,
              repeatable: false,
              defaultValue: null,
              description: 'My own version',
            ),
          ],
        ),
      );
      return cli;
    }

    test('a root route declaring --version fails at registration', () {
      expect(
        () => declaring(''),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.toString(),
            'message',
            allOf(contains('--version'), contains('reserved')),
          ),
        ),
      );
    });

    test('a route under a word may declare its own --version', () {
      expect(() => declaring('tool'), returnsNormally);
    });
  });
}
