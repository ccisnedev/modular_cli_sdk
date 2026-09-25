// A fifth review of PR #29 (feat/0.6.0), after the first four rounds'
// findings were fixed, found two more concrete defects (a third, about
// whether a resolved shortcut's help should show its own options, was
// checked against issue #27's body and its one amendment comment and found
// to name no such rule; that finding changes no behavior, so it has no test
// here and no CHANGELOG entry, only a note in the fix commit that reviewed
// it).
//
// Findings are numbered to match that fifth review, 1 and 2.

import 'dart:convert';

import 'package:modular_cli_sdk/modular_cli_sdk.dart';
import 'package:test/test.dart';

import 'doubles.dart';

// ── Finding 1 fixtures: shortcuts under every route shape a shortcut can ───
// ── take: a literal, an optional positional, a required positional, and ───
// ── one mounted under a module. ─────────────────────────────────────────────

class _WidgetInput extends Input {
  @override
  Map<String, dynamic> toJson() => {};
}

class _WidgetOutput extends Output {
  @override
  Map<String, dynamic> toJson() => {'ok': true};

  @override
  int get exitCode => ExitCode.ok;
}

class _WidgetQuery implements Query<_WidgetInput, _WidgetOutput> {
  _WidgetQuery(this.input);

  @override
  final _WidgetInput input;

  @override
  String? validate() => null;

  @override
  Future<_WidgetOutput> execute() async => _WidgetOutput();
}

/// The shortcut's own contract, shared by every fixture below: an optional
/// integer `a` and a required string `b`, exactly as the review finding
/// describes.
CliContract _shortcutOwnContract() => CliContract(
  options: [
    CliParam.integer(
      'a',
      abbr: null,
      required: false,
      repeatable: false,
      defaultValue: null,
      description: 'An integer the shortcut declares itself',
    ),
    CliParam.string(
      'b',
      abbr: null,
      required: true,
      repeatable: false,
      defaultValue: null,
      description: 'A required string the shortcut declares itself',
    ),
  ],
);

ModularCli _cliWithWidgetTarget() {
  final cli = ModularCli(suggestionDistance: 2);
  cli.query<_WidgetInput, _WidgetOutput>(
    'widget',
    (req) => _WidgetQuery(_WidgetInput()),
    globals: true,
    description: 'The shortcut target',
    contract: CliContract.none,
  );
  return cli;
}

/// A target declaring an optional `id` positional, so a shortcut can bind
/// it under either cardinality (issue #27 section 4: a shortcut rebinds a
/// target's own positional to whichever cardinality its own pattern gives
/// it).
ModularCli _cliWithWidgetTargetHavingOptionalId() {
  final cli = ModularCli(suggestionDistance: 2);
  cli.query<_WidgetInput, _WidgetOutput>(
    'widget [<id>]',
    (req) => _WidgetQuery(_WidgetInput()),
    globals: true,
    description: 'The shortcut target',
    contract: CliContract(
      positionals: [CliPositional.string('id', required: false)],
    ),
  );
  return cli;
}

/// Case: `s [<id>]`, an optional positional at the root.
ModularCli _cliWithOptionalPositionalShortcut() {
  final cli = _cliWithWidgetTargetHavingOptionalId();
  cli.shortcut(
    's [<id>]',
    target: 'widget',
    globals: true,
    contract: _shortcutOwnContract(),
  );
  return cli;
}

/// Case: `s <id>`, a required positional at the root.
ModularCli _cliWithRequiredPositionalShortcut() {
  final cli = _cliWithWidgetTargetHavingOptionalId();
  cli.shortcut(
    's <id>',
    target: 'widget',
    globals: true,
    contract: _shortcutOwnContract(),
  );
  return cli;
}

/// Case: `m s`, a literal shortcut mounted under module `m`.
ModularCli _cliWithModuleMountedShortcut() {
  final cli = ModularCli(suggestionDistance: 2);
  cli.query<_WidgetInput, _WidgetOutput>(
    'widget',
    (req) => _WidgetQuery(_WidgetInput()),
    globals: true,
    description: 'The shortcut target',
    contract: CliContract.none,
  );
  cli.module('m', (m) {
    m.shortcut(
      's',
      target: 'widget',
      globals: true,
      contract: _shortcutOwnContract(),
    );
  });
  return cli;
}

// ── Finding 2 fixture: nested middleware, one that fails to construct, one ─
// ── that escalates a nonzero result of its own. ────────────────────────────

ModularCli _cliForNestedMiddleware() {
  final cli = ModularCli(suggestionDistance: 2);
  cli.query<_WidgetInput, _WidgetOutput>(
    'widget',
    (req) => _WidgetQuery(_WidgetInput()),
    globals: true,
    description: 'A route to dispatch middleware through',
    contract: CliContract.none,
  );
  // Registered first: outermost. Runs `next` (the inner middleware wrapped
  // around the handler) and, seeing a nonzero result, escalates it into its
  // own thrown CommandException.
  cli.use((next) {
    return (req) async {
      final result = await next(req);
      if (result != 0) {
        throw CommandException(
          id: 'outer-middleware-saw-a-failure',
          message: 'the outer middleware escalated a nonzero result',
          exitCode: ExitCode.conflict,
        );
      }
      return result;
    };
  });
  // Registered second: innermost. Throws while building its own handler,
  // before ever seeing a request.
  cli.use((next) {
    throw CommandException(
      id: 'inner-middleware-construction-blew-up',
      message: 'the inner middleware failed while building its handler',
      exitCode: ExitCode.dataError,
    );
  });
  return cli;
}

void main() {
  group(
    'finding 1: shortcut validation must look up every route shape a '
    'shortcut can take, not just a bare literal',
    () {
      test(
        's [<id>] (an optional positional): --a bad --help must still '
        'report the bad --a value, not grant help',
        () async {
          final result = await _runWith(
            _cliWithOptionalPositionalShortcut(),
            ['s', '--json', '--a', 'bad', '--help'],
          );

          expect(result.exitCode, equals(ExitCode.validationFailed));
          final envelope = jsonDecode(result.stderr) as Map<String, dynamic>;
          final error = envelope['error'] as Map<String, dynamic>;
          expect(error['id'], equals('validation-failed'));
          expect(error['message'], contains('--a'));
        },
      );

      test(
        's <id> (a required positional), operand omitted: --a bad --help '
        'must still report the bad --a value, not grant help',
        () async {
          final result = await _runWith(
            _cliWithRequiredPositionalShortcut(),
            ['s', '--json', '--a', 'bad', '--help'],
          );

          expect(result.exitCode, equals(ExitCode.validationFailed));
          final envelope = jsonDecode(result.stderr) as Map<String, dynamic>;
          final error = envelope['error'] as Map<String, dynamic>;
          expect(error['id'], equals('validation-failed'));
          expect(error['message'], contains('--a'));
        },
      );

      test(
        'm s (mounted under a module): --a bad --help must still report '
        'the bad --a value, not grant help',
        () async {
          final result = await _runWith(_cliWithModuleMountedShortcut(), [
            'm',
            's',
            '--json',
            '--a',
            'bad',
            '--help',
          ]);

          expect(result.exitCode, equals(ExitCode.validationFailed));
          final envelope = jsonDecode(result.stderr) as Map<String, dynamic>;
          final error = envelope['error'] as Map<String, dynamic>;
          expect(error['id'], equals('validation-failed'));
          expect(error['message'], contains('--a'));
        },
      );
    },
  );

  group(
    'finding 2: exactly one error envelope is rendered per invocation, '
    'even across nested middleware boundaries',
    () {
      test(
        'an inner middleware that fails to construct, escalated by an '
        'outer middleware into its own throw, writes stderr as a single '
        'JSON document carrying the outer (terminating) error',
        () async {
          final result = await _runWith(_cliForNestedMiddleware(), [
            'widget',
            '--json',
          ]);

          expect(result.exitCode, equals(ExitCode.conflict));

          // The whole of stderr must decode as exactly one JSON document:
          // two envelopes concatenated would fail this decode outright.
          final envelope = jsonDecode(result.stderr) as Map<String, dynamic>;
          final error = envelope['error'] as Map<String, dynamic>;
          expect(error['id'], equals('outer-middleware-saw-a-failure'));
          expect(error['exitCode'], equals(ExitCode.conflict));
        },
      );

      test('the same nesting in text mode still writes only one message', () async {
        final result = await _runWith(_cliForNestedMiddleware(), ['widget']);

        expect(result.exitCode, equals(ExitCode.conflict));
        expect(
          result.stderr,
          contains('the outer middleware escalated a nonzero result'),
        );
        expect(
          result.stderr,
          isNot(contains('inner-middleware-construction-blew-up')),
        );
      });
    },
  );
}

// ── Test harness shared by every group ─────────────────────────────────────

Future<({int exitCode, String stdout, String stderr})> _runWith(
  ModularCli cli,
  List<String> args,
) async {
  final out = MemorySink();
  final err = MemorySink();
  final code = await cli.run(args, stdout: out, stderr: err);
  return (exitCode: code, stdout: out.output, stderr: err.output);
}
