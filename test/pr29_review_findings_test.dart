// Codex's review of PR #29 (feat/0.6.0) found ten concrete defects. Each
// group below reproduces the exact failure described in the review, then
// asserts the corrected behavior, through `ModularCli.run()` wherever the
// defect is only observable at that level, or as a direct unit test of the
// constructor/registration call that now throws.
//
// Findings are numbered to match the review, 1 through 10.

import 'dart:convert';
import 'dart:io';

import 'package:cli_router/cli_router.dart';
import 'package:modular_cli_sdk/modular_cli_sdk.dart';
import 'package:test/test.dart';

// ── Finding 1 & 7 & 8 fixture: `eval rpn [<program>]` ────────────────────

class _RpnInput extends Input {
  _RpnInput({this.program, required this.file, required this.stdinFlag});

  final String? program;
  final bool file;
  final bool stdinFlag;

  static final constraintContract = CliContract(
    positionals: [CliPositional.string('program', required: false)],
    options: [
      CliParam.flag('file', abbr: null, repeatable: false),
      CliParam.flag('stdin', abbr: null, repeatable: false),
    ],
    constraints: const [
      ExactlyOne(['program', 'file', 'stdin']),
    ],
  );

  factory _RpnInput.fromCliRequest(CliRequest req) => _RpnInput(
    program: req.param('program'),
    file: req.flagBool('file'),
    stdinFlag: req.flagBool('stdin'),
  );

  @override
  Map<String, dynamic> toJson() => {
    'program': program,
    'file': file,
    'stdin': stdinFlag,
  };
}

class _RpnOutput extends Output {
  _RpnOutput(this.source);
  final String source;

  @override
  Map<String, dynamic> toJson() => {'source': source};

  @override
  int get exitCode => ExitCode.ok;
}

class _RpnCommand implements Query<_RpnInput, _RpnOutput> {
  _RpnCommand(this.input);

  @override
  final _RpnInput input;

  @override
  String? validate() => null;

  @override
  Future<_RpnOutput> execute() async => _RpnOutput(
    input.program != null ? 'program' : (input.file ? 'file' : 'stdin'),
  );
}

ModularCli _buildConstraintCli() {
  final cli = ModularCli(suggestionDistance: 2);
  cli.module('eval', (m) {
    m.query<_RpnInput, _RpnOutput>(
      'rpn [<program>]',
      (req) => _RpnCommand(_RpnInput.fromCliRequest(req)),
      globals: true,
      description: 'Evaluate an RPN expression',
      contract: _RpnInput.constraintContract,
    );
  });
  return cli;
}

// ── Finding 7 & 8 & 9 fixture: `eval rpn [<program>]` with a required
//    `--mode`, plus an unrelated marker command so a test can prove help
//    stayed focused instead of falling back to the whole catalog ─────────

class _RpnModeInput extends Input {
  _RpnModeInput({this.program, required this.mode});

  final String? program;
  final String mode;

  static final contract = CliContract(
    positionals: [CliPositional.string('program', required: false)],
    options: [
      CliParam.enumeration(
        'mode',
        abbr: null,
        required: true,
        repeatable: false,
        values: const ['add', 'sub'],
        defaultValue: null,
        description: 'How to evaluate',
      ),
    ],
  );

  factory _RpnModeInput.fromCliRequest(CliRequest req) => _RpnModeInput(
    program: req.param('program'),
    mode: req.flagString('mode')!,
  );

  @override
  Map<String, dynamic> toJson() => {'program': program, 'mode': mode};
}

class _RpnModeCommand implements Query<_RpnModeInput, _RpnOutput> {
  _RpnModeCommand(this.input);

  @override
  final _RpnModeInput input;

  @override
  String? validate() => null;

  @override
  Future<_RpnOutput> execute() async => _RpnOutput(input.mode);
}

class _MarkerInput extends Input {
  @override
  Map<String, dynamic> toJson() => {};
}

class _MarkerOutput extends Output {
  @override
  Map<String, dynamic> toJson() => {'ok': true};

  @override
  int get exitCode => ExitCode.ok;
}

class _MarkerCommand implements Query<_MarkerInput, _MarkerOutput> {
  _MarkerCommand(this.input);

  @override
  final _MarkerInput input;

  @override
  String? validate() => null;

  @override
  Future<_MarkerOutput> execute() async => _MarkerOutput();
}

ModularCli _buildIdentityCli() {
  final cli = ModularCli(suggestionDistance: 2);
  cli.module('eval', (m) {
    m.query<_RpnModeInput, _RpnOutput>(
      'rpn [<program>]',
      (req) => _RpnModeCommand(_RpnModeInput.fromCliRequest(req)),
      globals: true,
      description: 'Evaluate an RPN expression',
      contract: _RpnModeInput.contract,
    );
  });
  cli.query<_MarkerInput, _MarkerOutput>(
    'unrelated-marker-command',
    (req) => _MarkerCommand(_MarkerInput()),
    globals: true,
    description: 'A totally unrelated marker command',
    contract: CliContract.none,
  );
  return cli;
}

// ── Finding 2 fixture: shortcut() ─────────────────────────────────────────

ModularCli _buildShortcutCli() {
  final cli = _buildConstraintCli();
  cli.shortcut(
    '<program>',
    target: 'eval rpn',
    globals: false,
    contract: CliContract.none,
  );
  return cli;
}

// ── Finding 4 fixture: `show <id>`, the exact "typo" case from the
//    review, plus a `note [<name>]` route for the optional-cardinality
//    cases ────────────────────────────────────────────────────────────────

class _ShowInput extends Input {
  _ShowInput(this.id);
  final int id;

  factory _ShowInput.fromCliRequest(CliRequest req) =>
      _ShowInput(int.parse(req.param('id')!));

  @override
  Map<String, dynamic> toJson() => {'id': id};
}

class _ShowOutput extends Output {
  _ShowOutput(this.id);
  final int id;

  @override
  Map<String, dynamic> toJson() => {'id': id};

  @override
  int get exitCode => ExitCode.ok;
}

class _ShowCommand implements Query<_ShowInput, _ShowOutput> {
  _ShowCommand(this.input);

  @override
  final _ShowInput input;

  @override
  String? validate() => null;

  @override
  Future<_ShowOutput> execute() async => _ShowOutput(input.id);
}

// ── Finding 5 fixture: a repeatable option ────────────────────────────────

class _RepeatInput extends Input {
  _RepeatInput(this.counts);
  final List<int> counts;

  static final contract = CliContract(
    options: [
      CliParam.integer(
        'count',
        abbr: null,
        required: false,
        repeatable: true,
        defaultValue: null,
        description: 'One or more counts',
      ),
    ],
  );

  @override
  Map<String, dynamic> toJson() => {'counts': counts};
}

class _RepeatOutput extends Output {
  _RepeatOutput(this.n);
  final int n;

  @override
  Map<String, dynamic> toJson() => {'n': n};

  @override
  int get exitCode => ExitCode.ok;
}

class _RepeatCommand implements Query<_RepeatInput, _RepeatOutput> {
  _RepeatCommand(this.input);

  @override
  final _RepeatInput input;

  @override
  String? validate() => null;

  @override
  Future<_RepeatOutput> execute() async => _RepeatOutput(input.counts.length);
}

ModularCli _buildRepeatCli() {
  final cli = ModularCli(suggestionDistance: 2);
  cli.query<_RepeatInput, _RepeatOutput>(
    'repeat',
    (req) => _RepeatCommand(_RepeatInput(const [])),
    globals: true,
    description: 'Takes a repeatable option',
    contract: _RepeatInput.contract,
  );
  return cli;
}

// ── Finding 6 fixture: a `mustExist` path default that does not exist ────

class _ConfigInput extends Input {
  @override
  Map<String, dynamic> toJson() => {};
}

class _ConfigOutput extends Output {
  @override
  Map<String, dynamic> toJson() => {'ok': true};

  @override
  int get exitCode => ExitCode.ok;
}

class _ConfigCommand implements Query<_ConfigInput, _ConfigOutput> {
  _ConfigCommand(this.input);

  @override
  final _ConfigInput input;

  @override
  String? validate() => null;

  @override
  Future<_ConfigOutput> execute() async => _ConfigOutput();
}

// ── Finding 10 fixture: a typo'd nested command ───────────────────────────

ModularCli _buildSuggestCli() {
  final cli = ModularCli(suggestionDistance: 2);
  cli.module('commands', (m) {
    m.query<_ShowInput, _ShowOutput>(
      'show <id>',
      (req) => _ShowCommand(_ShowInput.fromCliRequest(req)),
      globals: true,
      description: 'Show a record',
      contract: CliContract(
        positionals: [CliPositional.integer('id', required: true)],
      ),
    );
  });
  return cli;
}

// ── Test harness shared by every group ────────────────────────────────────

Future<({int exitCode, String stdout, String stderr})> _runWith(
  ModularCli cli,
  List<String> args,
) async {
  final out = _TestSink();
  final err = _TestSink();
  final code = await cli.run(args, stdout: out, stderr: err);
  return (exitCode: code, stdout: out.toString(), stderr: err.toString());
}

void main() {
  // ── 1. Constraints must count bound positionals ────────────────────────
  group('finding 1: a constraint counts a bound positional as present', () {
    test(
      'the positional alone satisfies ExactlyOne and the route runs',
      () async {
        final result = await _runWith(_buildConstraintCli(), [
          'eval',
          'rpn',
          '1 2 +',
        ]);

        expect(result.exitCode, equals(ExitCode.ok));
        expect(result.stdout, contains('source: program'));
      },
    );

    test('a flag alone still satisfies it, exactly as before', () async {
      final result = await _runWith(_buildConstraintCli(), [
        'eval',
        'rpn',
        '--file',
      ]);

      expect(result.exitCode, equals(ExitCode.ok));
      expect(result.stdout, contains('source: file'));
    });

    test('none present is still a violation', () async {
      final result = await _runWith(_buildConstraintCli(), ['eval', 'rpn']);

      expect(result.exitCode, equals(ExitCode.validationFailed));
      expect(result.stderr, contains('Choose one of'));
    });

    test(
      'a flag AND the positional together now violates ExactlyOne '
      '(previously ran, because the positional was invisible to it)',
      () async {
        final result = await _runWith(_buildConstraintCli(), [
          'eval',
          'rpn',
          '--file',
          '1 2 +',
        ]);

        expect(result.exitCode, equals(ExitCode.validationFailed));
        expect(result.stderr, contains('Choose one of'));
      },
    );
  });

  // ── 2. shortcut() ────────────────────────────────────────────────────────
  group('finding 2: shortcut() runs the target under a narrower contract', () {
    test('a bare positional dispatches to the target handler', () async {
      final result = await _runWith(_buildShortcutCli(), ['1 2 +']);

      expect(result.exitCode, equals(ExitCode.ok));
      expect(result.stdout, contains('source: program'));
    });

    test(
      'globals: false rejects a global option the target itself accepts',
      () async {
        final result = await _runWith(_buildShortcutCli(), ['--json', '1 2 +']);

        expect(result.exitCode, isNot(equals(ExitCode.ok)));
      },
    );

    test('a shortcut to an unregistered target is an ArgumentError', () {
      expect(
        () => ModularCli(suggestionDistance: 2).shortcut(
          '<x>',
          target: 'nope',
          globals: false,
          contract: CliContract(
            positionals: [CliPositional.string('x', required: true)],
          ),
        ),
        throwsArgumentError,
      );
    });

    // Issue #27, section 4, gives this exact line as the shorthand a caller
    // should be able to write, `contract` named explicitly the same way
    // query() and command() require it: no undeclared, defaulted contract.
    // `program` is still derived from the target and rebound `required` by
    // the route pattern.
    test('the exact issue #27 example runs, contract named explicitly', () async {
      final cli = _buildConstraintCli();
      cli.shortcut(
        '<program>',
        target: 'eval rpn',
        globals: false,
        contract: CliContract.none,
      );

      final result = await _runWith(cli, ['1 2 +']);

      expect(result.exitCode, equals(ExitCode.ok));
      expect(result.stdout, contains('source: program'));
    });
  });

  // ── 3. cli.module('', ...) ────────────────────────────────────────────────
  group("finding 3: cli.module('', ...) registers directly on the root", () {
    test('it does not throw, and the route it declares runs', () async {
      final cli = ModularCli(suggestionDistance: 2);
      expect(
        () => cli.module('', (m) {
          m.query<_MarkerInput, _MarkerOutput>(
            'root-thing',
            (req) => _MarkerCommand(_MarkerInput()),
            globals: true,
            description: 'Registered through the empty module',
            contract: CliContract.none,
          );
        }),
        returnsNormally,
      );

      final result = await _runWith(cli, ['root-thing']);
      expect(result.exitCode, equals(ExitCode.ok));
    });

    test('the registered route belongs to no module', () {
      final cli = ModularCli(suggestionDistance: 2);
      cli.module('', (m) {
        m.query<_MarkerInput, _MarkerOutput>(
          'root-thing',
          (req) => _MarkerCommand(_MarkerInput()),
          globals: true,
          contract: CliContract.none,
        );
      });

      final contract = cli.catalog.forName('root-thing');
      expect(contract, isNotNull);
      expect(contract!.module, isEmpty);
    });
  });

  // ── 4. Positional declarations must match the route pattern ─────────────
  group('finding 4: a route/contract positional mismatch is an ArgumentError '
      'at registration', () {
    test('a misnamed positional (the exact review example)', () {
      // `show <id>` registered with `CliPositional.integer('typo')`: this
      // used to register successfully, and `show bad` used to exit 0
      // because `CliContract.none`-like enforcement never checked the
      // positional's name against the route at all.
      final cli = ModularCli(suggestionDistance: 2);
      expect(
        () => cli.query<_ShowInput, _ShowOutput>(
          'show <id>',
          (req) => _ShowCommand(_ShowInput.fromCliRequest(req)),
          globals: true,
          contract: CliContract(
            positionals: [CliPositional.integer('typo', required: true)],
          ),
        ),
        throwsArgumentError,
      );
    });

    test('a missing positional declaration', () {
      final cli = ModularCli(suggestionDistance: 2);
      expect(
        () => cli.query<_ShowInput, _ShowOutput>(
          'show <id>',
          (req) => _ShowCommand(_ShowInput.fromCliRequest(req)),
          globals: true,
          contract: CliContract.none,
        ),
        throwsArgumentError,
      );
    });

    test('an extra positional declaration', () {
      final cli = ModularCli(suggestionDistance: 2);
      expect(
        () => cli.query<_MarkerInput, _MarkerOutput>(
          'show',
          (req) => _MarkerCommand(_MarkerInput()),
          globals: true,
          contract: CliContract(
            positionals: [CliPositional.integer('id', required: true)],
          ),
        ),
        throwsArgumentError,
      );
    });

    test('a duplicate positional declaration', () {
      final cli = ModularCli(suggestionDistance: 2);
      expect(
        () => cli.query<_ShowInput, _ShowOutput>(
          'show <id>',
          (req) => _ShowCommand(_ShowInput.fromCliRequest(req)),
          globals: true,
          contract: CliContract(
            positionals: [
              CliPositional.integer('id', required: true),
              CliPositional.integer('id', required: true),
            ],
          ),
        ),
        throwsArgumentError,
      );
    });

    test('a route-optional segment declared required is an ArgumentError', () {
      final cli = ModularCli(suggestionDistance: 2);
      expect(
        () => cli.query<_MarkerInput, _MarkerOutput>(
          'note [<name>]',
          (req) => _MarkerCommand(_MarkerInput()),
          globals: true,
          contract: CliContract(
            positionals: [CliPositional.string('name', required: true)],
          ),
        ),
        throwsArgumentError,
      );
    });

    test(
      'a route-required segment declared optional is also an ArgumentError',
      () {
        final cli = ModularCli(suggestionDistance: 2);
        expect(
          () => cli.query<_MarkerInput, _MarkerOutput>(
            'note <name>',
            (req) => _MarkerCommand(_MarkerInput()),
            globals: true,
            contract: CliContract(
              positionals: [CliPositional.string('name', required: false)],
            ),
          ),
          throwsArgumentError,
        );
      },
    );

    test('declared correctly, an optional segment registers and runs both '
        'with and without it', () async {
      final cli = ModularCli(suggestionDistance: 2);
      cli.query<_MarkerInput, _MarkerOutput>(
        'note [<name>]',
        (req) => _MarkerCommand(_MarkerInput()),
        globals: true,
        contract: CliContract(
          positionals: [CliPositional.string('name', required: false)],
        ),
      );

      final withArg = await _runWith(cli, ['note', 'shopping']);
      final withoutArg = await _runWith(cli, ['note']);

      expect(withArg.exitCode, equals(ExitCode.ok));
      expect(withoutArg.exitCode, equals(ExitCode.ok));
    });
  });

  // ── 5. Repeatable options validate every occurrence ─────────────────────
  group('finding 5: every occurrence of a repeatable option is validated', () {
    test('every valid occurrence runs', () async {
      final result = await _runWith(_buildRepeatCli(), [
        'repeat',
        '--count',
        '1',
        '--count',
        '2',
      ]);

      expect(result.exitCode, equals(ExitCode.ok));
    });

    test('a bad second occurrence is rejected (previously exited 0, because '
        'only the first occurrence was ever validated)', () async {
      final result = await _runWith(_buildRepeatCli(), [
        'repeat',
        '--count',
        '1',
        '--count',
        'bad',
      ]);

      expect(result.exitCode, equals(ExitCode.validationFailed));
      expect(result.stderr, contains('--count'));
    });
  });

  // ── 6. A DeclaredDefault must satisfy its own declaration ────────────────
  group('finding 6: a DeclaredDefault is validated like a given value', () {
    test('an enum default outside its own allowed values is an ArgumentError '
        'at CliParam construction', () {
      expect(
        () => CliParam.enumeration(
          'format',
          abbr: null,
          required: false,
          repeatable: false,
          values: const ['text', 'shout'],
          defaultValue: const DeclaredDefault('xml', reason: 'bogus'),
        ),
        throwsArgumentError,
      );
    });

    test('a mustExist path default that does not exist on disk is rejected at '
        'dispatch time, exactly like a value the caller had typed', () async {
      final missingPath =
          '${Directory.systemTemp.path}/definitely-missing-'
          '${DateTime.now().microsecondsSinceEpoch}.cfg';

      final cli = ModularCli(suggestionDistance: 2);
      cli.query<_ConfigInput, _ConfigOutput>(
        'cfg',
        (req) => _ConfigCommand(_ConfigInput()),
        globals: true,
        contract: CliContract(
          options: [
            CliParam.path(
              'config',
              abbr: null,
              required: false,
              repeatable: false,
              mustExist: true,
              defaultValue: DeclaredDefault(
                missingPath,
                reason: 'a default nobody put there',
              ),
            ),
          ],
        ),
      );

      final result = await _runWith(cli, ['cfg']);

      expect(result.exitCode, equals(ExitCode.validationFailed));
      expect(result.stderr, contains('--config'));
    });
  });

  // ── 7. Route identity: help, focused help, and JSON errors ─────────────
  group(
    'finding 7: an optional-positional route is identified consistently',
    () {
      test(
        '`help eval rpn` returns that command, not the whole catalog',
        () async {
          final result = await _runWith(_buildIdentityCli(), [
            'help',
            'eval',
            'rpn',
          ]);

          expect(result.exitCode, equals(ExitCode.ok));
          expect(result.stdout, contains('eval rpn'));
          expect(result.stdout, contains('mode'));
          expect(
            result.stdout,
            isNot(contains('unrelated-marker-command')),
            reason: '`help eval rpn` must not fall back to the full catalog',
          );
        },
      );

      test('`eval rpn --help` with a missing required option shows the '
          "command's own help, not the module's or the catalog's", () async {
        final result = await _runWith(_buildIdentityCli(), [
          'eval',
          'rpn',
          '--help',
        ]);

        expect(result.exitCode, equals(ExitCode.ok));
        expect(result.stdout, contains('Usage: eval rpn'));
        expect(result.stdout, contains('mode'));
        expect(
          result.stdout,
          isNot(contains('unrelated-marker-command')),
          reason: 'focused help must not widen to the module or catalog',
        );
      });

      test(
        'a JSON rejection for the same route keeps its contract and details',
        () async {
          final result = await _runWith(_buildIdentityCli(), [
            'eval',
            'rpn',
            '--json',
          ]);

          expect(result.exitCode, equals(ExitCode.validationFailed));
          final envelope = jsonDecode(result.stderr) as Map<String, dynamic>;
          final error = envelope['error'] as Map<String, dynamic>;
          expect(error['contract'], isNotNull);
          expect(error['details'], containsPair('parameter', 'mode'));
        },
      );
    },
  );

  // ── 8. Help usage text for an optional positional ────────────────────────
  group('finding 8: usage text for an optional positional', () {
    test('is `Usage: eval rpn [options] [<program>]`, never `[] ... <program>` '
        'and never marked required', () async {
      final result = await _runWith(_buildIdentityCli(), [
        'eval',
        'rpn',
        '--help',
      ]);

      expect(result.stdout, contains('Usage: eval rpn [options] [<program>]'));
      expect(result.stdout, isNot(contains('eval rpn []')));
      expect(result.stdout, contains('<program>'));
      expect(result.stdout, contains('optional'));
    });
  });

  // ── 9. Message rewriting is keyed on kind alone ──────────────────────────
  group('finding 9: the "not a complete command" rewrite never applies to a '
      'kind other than incomplete, even under --json', () {
    test(
      'eval --json --bogus keeps the router\'s own unknownOption message',
      () async {
        final result = await _runWith(_buildIdentityCli(), [
          'eval',
          '--json',
          '--bogus',
        ]);

        final envelope = jsonDecode(result.stderr) as Map<String, dynamic>;
        final error = envelope['error'] as Map<String, dynamic>;
        expect(error['id'], equals('unknown-option'));
        expect(error['message'], isNot(contains('not a complete command')));
        expect(error['message'], contains('--bogus'));
      },
    );
  });

  // ── 10. suggest() ─────────────────────────────────────────────────────────
  group('finding 10: CommandCatalog.suggest()', () {
    test('finds a close registered word within the default distance', () {
      final catalog = CommandCatalog();
      catalog.register(
        CommandContract(
          route: 'show <id>',
          module: '',
          globals: true,
          contract: CliContract(
            positionals: [CliPositional.integer('id', required: true)],
          ),
        ),
      );

      expect(catalog.suggest('shwo'), equals('show'));
    });

    test('returns null when nothing registered is close enough', () {
      final catalog = CommandCatalog();
      catalog.register(
        CommandContract(
          route: 'show <id>',
          module: '',
          globals: true,
          contract: CliContract.none,
        ),
      );

      expect(catalog.suggest('zzzzzzzzzzzzzzzzzzzz'), isNull);
    });

    test('breaks a tie in distance by catalog registration order', () {
      final catalog = CommandCatalog();
      catalog.register(
        CommandContract(
          route: 'a',
          module: '',
          globals: true,
          contract: CliContract.none,
        ),
      );
      catalog.register(
        CommandContract(
          route: 'b',
          module: '',
          globals: true,
          contract: CliContract.none,
        ),
      );

      // Both 'a' and 'b' are one substitution away from 'c'; 'a' was
      // registered first.
      expect(catalog.suggest('c'), equals('a'));
    });

    test('a typo one segment into a route suggests the word it was closest to, '
        'through ModularCli.run()', () async {
      final result = await _runWith(_buildSuggestCli(), [
        'commands',
        'shwo',
        '5',
      ]);

      expect(result.stderr, contains("Did you mean 'show'?"));
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
