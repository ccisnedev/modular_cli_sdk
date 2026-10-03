import 'dart:convert';

import 'package:modular_cli_sdk/modular_cli_sdk.dart';
import 'package:test/test.dart';

import 'doubles.dart';

// Issue #50: an optional help epilog, printed once after the full,
// unnarrowed catalog (help, root --help / -h, the built-in bare catalog,
// printHelp) and nowhere else.

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

ModularCli _cli({
  String? epilog,
  bool rootRoute = false,
  bool rootShortcut = false,
  bool withParam = true,
}) {
  final cli = withParam
      ? ModularCli(
          suggestionDistance: 2,
          name: 'x',
          version: '1.2.3',
          helpEpilog: epilog,
        )
      : ModularCli(suggestionDistance: 2, name: 'x', version: '1.2.3');
  cli.module('eval', (m) {
    m.query<_NoInput, _TextOutput>(
      'rpn [<program>]',
      (req) => _TextQuery('ran'),
      globals: true,
      description: 'Evaluate an RPN program',
      contract: CliContract(
        positionals: [CliPositional.string('program', required: false)],
      ),
    );
    m.query<_NoInput, _TextOutput>(
      'rpn trace',
      (req) => _TextQuery('trace'),
      globals: true,
      description: 'Trace an RPN program',
      contract: CliContract.none,
    );
  });
  if (rootRoute) {
    cli.query<_NoInput, _TextOutput>(
      '',
      (req) => _TextQuery('dashboard'),
      globals: true,
      description: 'The dashboard',
      contract: CliContract.none,
    );
  }
  if (rootShortcut) {
    cli.shortcut(
      '[<program>]',
      target: 'eval rpn',
      globals: true,
      description: 'Evaluate a program',
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

String _printHelp(ModularCli cli) {
  final sink = MemorySink();
  cli.printHelp(sink);
  return sink.output;
}

void main() {
  group('null epilog changes nothing', () {
    for (final args in [
      ['help'],
      ['--help'],
      ['-h'],
      ['help', '--json'],
      ['--help', '--json'],
      <String>[],
    ]) {
      test('x ${args.join(' ')}', () async {
        // Built without the parameter vs. with an explicit null.
        final a = await _run(_cli(withParam: false), args);
        final b = await _run(_cli(epilog: null), args);
        expect(b.stdout, a.stdout);
        expect(b.stderr, a.stderr);
      });
    }
  });

  group('epilog closes the full catalog', () {
    // The catalog without an epilog, plus one empty line, plus the epilog.
    Future<void> expectEpilogAfter(List<String> args) async {
      final plain = await _run(_cli(), args);
      final withEpilog = await _run(_cli(epilog: _epilog), args);
      expect(withEpilog.exitCode, ExitCode.ok);
      expect(withEpilog.stdout, '${plain.stdout}\n$_epilog\n');
      expect(plain.stdout.trimRight(), contains('Global options:'));
      expect(plain.stdout, isNot(contains('Examples:')));
    }

    test('x help', () => expectEpilogAfter(['help']));
    test('x --help', () => expectEpilogAfter(['--help']));
    test('x -h', () => expectEpilogAfter(['-h']));
    test('x --help --quiet', () => expectEpilogAfter(['--help', '--quiet']));

    test('bare x with no root route or shortcut (built-in catalog)', () async {
      await expectEpilogAfter(<String>[]);
    });

    test('printHelp', () {
      final plain = _printHelp(_cli());
      final withEpilog = _printHelp(_cli(epilog: _epilog));
      expect(withEpilog, '$plain\n$_epilog\n');
    });
  });

  group('epilog stays out of everything else', () {
    test('bare x with a root route runs the route', () async {
      final r = await _run(_cli(epilog: _epilog, rootRoute: true), []);
      expect(r.stdout, contains('dashboard'));
      expect(r.stdout, isNot(contains('Examples:')));
    });

    test('bare x with a root shortcut', () async {
      final r = await _run(_cli(epilog: _epilog, rootShortcut: true), []);
      expect(r.stdout, isNot(contains('Examples:')));
      expect(r.stderr, isNot(contains('Examples:')));
    });

    for (final args in [
      ['eval', '--help'],
      ['help', 'eval'],
      ['eval', 'rpn', '--help'],
      ['help', 'eval', 'rpn'],
      ['eval', 'rpn', '--help', '--json'],
      ['eval'],
      ['eval', 'rpn', 'trace', 'extra', '--bogus'],
      ['nope'],
      ['eval', 'nope'],
      ['--bogus'],
    ]) {
      test('x ${args.join(' ')}', () async {
        final r = await _run(_cli(epilog: _epilog), args);
        expect(r.stdout, isNot(contains('Examples:')));
        expect(r.stderr, isNot(contains('Examples:')));
      });
    }
  });

  group('JSON', () {
    for (final args in [
      ['help', '--json'],
      ['--help', '--json'],
    ]) {
      test('x ${args.join(' ')} carries epilog after the other keys', () async {
        final r = await _run(_cli(epilog: 'tip\n\n'), args);
        final json = jsonDecode(r.stdout) as Map<String, dynamic>;
        expect(json['epilog'], 'tip');
        expect(json.keys.last, 'epilog');
      });

      test('x ${args.join(' ')} has no epilog key when null', () async {
        final r = await _run(_cli(), args);
        expect((jsonDecode(r.stdout) as Map).containsKey('epilog'), isFalse);
      });
    }

    for (final args in [
      ['help', '--json', 'eval'],
      ['eval', '--help', '--json'],
      ['help', '--json', 'eval', 'rpn'],
      ['eval', 'rpn', '--help', '--json'],
    ]) {
      test('x ${args.join(' ')} has no epilog key', () async {
        final r = await _run(_cli(epilog: _epilog), args);
        expect(r.stdout, isNot(contains('Examples:')));
        expect((jsonDecode(r.stdout) as Map).containsKey('epilog'), isFalse);
      });
    }
  });

  group('constructor', () {
    for (final bad in ['', '   ', '\n\n']) {
      test('${jsonEncode(bad)} throws ArgumentError', () {
        expect(
          () => ModularCli(suggestionDistance: 2, helpEpilog: bad),
          throwsArgumentError,
        );
      });
    }

    test('only trailing whitespace is dropped', () async {
      final r = await _run(_cli(epilog: '  tip\n\n'), ['help']);
      expect(r.stdout, endsWith('\n\n  tip\n'));
    });

    test('tip with trailing newlines is stored and printed as tip', () async {
      final plain = await _run(_cli(), ['help']);
      final r = await _run(_cli(epilog: 'tip\n\n'), ['help']);
      expect(r.stdout, '${plain.stdout}\ntip\n');
    });
  });

  test('--help, -h and help print the same text with an epilog', () async {
    final help = await _run(_cli(epilog: _epilog), ['help']);
    final long = await _run(_cli(epilog: _epilog), ['--help']);
    final short = await _run(_cli(epilog: _epilog), ['-h']);
    expect(long.stdout, help.stdout);
    expect(short.stdout, help.stdout);
  });
}
