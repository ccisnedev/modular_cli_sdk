// Codex round 14 of PR #29 (feat/0.6.0) found two more issues.
//
// Finding 1 (invocation_outcome.dart, InvocationOutcome.runAttempt): a
// downstream attempt that ultimately recovers, that is, whose whole `next()`
// call answers ExitCode.ok, used to hand its enclosing middleware's own
// runAttempt call whatever landed in its own frame regardless of that
// success, because a nested ModularCli.use() middleware's own reconcile()
// (see its own doc comment) copies the latest attempt's recording into
// whatever frame is ambient purely by comparing RecordedOutcome.recordedAt,
// with no way to tell "the nested middleware answered failure" apart from
// "the nested middleware answered success, so whatever it recorded along the
// way was already recovered from". Two levels of nesting exposed this: an
// outer middleware records its own error, calls next() (an inner middleware
// that awaits a handler failure and recovers by returning ExitCode.ok
// itself), and the outer's own, already-recorded error ends up silently
// overwritten by the inner, recovered failure once the outer's own
// runAttempt call folds it in, even though the inner middleware itself
// answered success.
//
// The fix (already applied to invocation_outcome.dart) discards a frame's
// recording before ever handing it to onSettled whenever body's own return
// value is ExitCode.ok, so only a next() call that itself ends in failure
// ever has anything to propagate upward.
//
// Finding 2 (modular_cli.dart, _resolveHelpProvenance): checking
// _shortcutContractsByExactRoute by the exact key "help" (round-13's own
// fix) only ever caught a shortcut whose trailing positional is optional or
// a wildcard, both of which ModuleBuilder.shortcut strips from that map's
// own key; a shortcut with a required positional (shortcut('help <topic>',
// ...)) keeps it in the key ("help <topic>"), so the exact-key lookup missed
// it just as the pre-round-13 catalog-only check once did, registering the
// built-in default over it and throwing on the very first run() call.
//
// The fix (already applied to modular_cli.dart) replaces both the catalog
// check and the shortcut-map check with one shared predicate, _isNamedHelp,
// reusing the exact same name-stripping rule CommandContract.name already
// gives an ordinary route, so a route or a shortcut named "help" is told
// apart from the built-in default regardless of which of the two registered
// it or what cardinality its own positional declares.

import 'dart:convert';

import 'package:cli_router/cli_router.dart' show CliMiddleware;
import 'package:modular_cli_sdk/modular_cli_sdk.dart';
import 'package:test/test.dart';

import 'doubles.dart';

// ── Shared fixtures ─────────────────────────────────────────────────────────

class _WidgetInput extends Input {
  @override
  Map<String, dynamic> toJson() => {};
}

class _WidgetOutput extends Output {
  _WidgetOutput({this.marker = 'ok'});

  final String marker;

  @override
  Map<String, dynamic> toJson() => {'marker': marker};

  @override
  int get exitCode => ExitCode.ok;
}

class _OkQuery implements Query<_WidgetInput, _WidgetOutput> {
  _OkQuery({this.marker = 'ok'});

  final String marker;

  @override
  final _WidgetInput input = _WidgetInput();

  @override
  String? validate() => null;

  @override
  Future<_WidgetOutput> execute() async => _WidgetOutput(marker: marker);
}

Future<({int exitCode, String stdout, String stderr})> _runWith(
  ModularCli cli,
  List<String> args,
) async {
  final out = MemorySink();
  final err = MemorySink();
  final code = await cli.run(args, stdout: out, stderr: err);
  return (exitCode: code, stdout: out.output, stderr: err.output);
}

// ── Finding 1 fixtures ───────────────────────────────────────────────────────

/// Always throws [error]: caught internally by ModuleBuilder's own handler
/// wrapping, recorded into whichever frame is current at that point, and
/// turned into a directly-returned exit code, never rethrown past the
/// handler dispatch itself.
class _FailingQuery implements Query<_WidgetInput, _WidgetOutput> {
  _FailingQuery(this.error);

  final CommandException error;

  @override
  final _WidgetInput input = _WidgetInput();

  @override
  String? validate() => null;

  @override
  Future<_WidgetOutput> execute() async => throw error;
}

/// The innermost of two nested middlewares: awaits its own next() call (the
/// handler dispatch below it, which always fails), then recovers from it by
/// returning ExitCode.ok directly, discarding whatever next() itself
/// returned. Records nothing of its own.
CliMiddleware _recoversByReturningOkRegardlessOfNext() => (next) {
  return (req) async {
    await next(req);
    return ExitCode.ok;
  };
};

/// The outermost of two nested middlewares: records [ownError] directly,
/// strictly BEFORE calling next() (the inner, recovering middleware below
/// it), then returns [ownError.exitCode] regardless of what next() itself
/// returned. The "fail-then-recover" order the finding names: the outer's
/// own failure is recorded first, the inner recovery happens after it.
CliMiddleware _recordsOwnBeforeThenCallsARecoveringNext(
  CommandException ownError,
) => (next) {
  return (req) async {
    JsonCliOutput(stdout: req.stdout, stderr: req.stderr).writeError(ownError);
    await next(req);
    return ownError.exitCode;
  };
};

/// The outermost of two nested middlewares: calls next() (the inner,
/// recovering middleware below it) FIRST, then records [ownError] directly
/// afterward and returns [ownError.exitCode]. The "recover-then-fail" order
/// the finding names: the inner recovery happens first, the outer's own
/// failure is recorded after it.
CliMiddleware _callsARecoveringNextThenRecordsOwnAfterward(
  CommandException ownError,
) => (next) {
  return (req) async {
    await next(req);
    JsonCliOutput(stdout: req.stdout, stderr: req.stderr).writeError(ownError);
    return ownError.exitCode;
  };
};

ModularCli _cliWithNestedRecoveryAndAnOuterErrorRecordedBeforeRecovering(
  CommandException innerError,
  CommandException outerOwnError,
) {
  final cli = ModularCli(suggestionDistance: 2);
  cli.query<_WidgetInput, _WidgetOutput>(
    'widget',
    (req) => _FailingQuery(innerError),
    globals: true,
    contract: CliContract.none,
  );
  cli.use(_recordsOwnBeforeThenCallsARecoveringNext(outerOwnError));
  cli.use(_recoversByReturningOkRegardlessOfNext());
  return cli;
}

ModularCli _cliWithNestedRecoveryAndAnOuterErrorRecordedAfterRecovering(
  CommandException innerError,
  CommandException outerOwnError,
) {
  final cli = ModularCli(suggestionDistance: 2);
  cli.query<_WidgetInput, _WidgetOutput>(
    'widget',
    (req) => _FailingQuery(innerError),
    globals: true,
    contract: CliContract.none,
  );
  cli.use(_callsARecoveringNextThenRecordsOwnAfterward(outerOwnError));
  cli.use(_recoversByReturningOkRegardlessOfNext());
  return cli;
}

// ── Finding 2 fixtures ───────────────────────────────────────────────────────

/// A `manual <topic>` route (a required positional), plus a shortcut naming
/// it `help <topic>`: the exact shape the finding names, a shortcut whose
/// trailing positional is required, which round-13's own exact-key check
/// missed since [ModuleBuilder.shortcut] keeps a required positional in that
/// key instead of stripping it.
ModularCli _cliWithARequiredPositionalShortcutNamedHelp() {
  final cli = ModularCli(suggestionDistance: 2);
  cli.query<_WidgetInput, _WidgetOutput>(
    'manual <topic>',
    (req) => _OkQuery(marker: 'manual-ran'),
    globals: true,
    contract: CliContract(
      positionals: [CliPositional.string('topic', required: true)],
    ),
  );
  cli.shortcut(
    'help <topic>',
    target: 'manual',
    globals: true,
    contract: CliContract.none,
  );
  return cli;
}

/// A `manual [<topic>]` route (an optional positional), plus a shortcut naming
/// it `help [<topic>]`: round-13's own exact-key check already caught this
/// shape correctly (an optional positional is stripped from the key), so
/// this guards the shared predicate against regressing a case that already
/// worked.
ModularCli _cliWithAnOptionalPositionalShortcutNamedHelp() {
  final cli = ModularCli(suggestionDistance: 2);
  cli.query<_WidgetInput, _WidgetOutput>(
    'manual [<topic>]',
    (req) => _OkQuery(marker: 'manual-ran'),
    globals: true,
    contract: CliContract(
      positionals: [CliPositional.string('topic', required: false)],
    ),
  );
  cli.shortcut(
    'help [<topic>]',
    target: 'manual',
    globals: true,
    contract: CliContract.none,
  );
  return cli;
}

/// A bare `manual` route (no positional at all), plus a shortcut naming it
/// `help *`: a trailing wildcard derives no positional from its target
/// either (RoutePattern.positionals never includes a wildcard segment), so
/// this is the same shape as a bare `help` shortcut as far as
/// ModuleBuilder.shortcut and the exact-key map are concerned; round-13's
/// own exact-key check already caught this shape too (a wildcard is
/// stripped from the key exactly like an optional positional), so this is
/// the same regression guard as the optional-positional case above, for the
/// other shape [_shortcutContractsByExactRoute]'s key already strips.
ModularCli _cliWithAWildcardShortcutNamedHelp() {
  final cli = ModularCli(suggestionDistance: 2);
  cli.query<_WidgetInput, _WidgetOutput>(
    'manual',
    (req) => _OkQuery(marker: 'manual-ran'),
    globals: true,
    contract: CliContract.none,
  );
  cli.shortcut(
    'help *',
    target: 'manual',
    globals: true,
    contract: CliContract.none,
  );
  return cli;
}

void main() {
  group(
    'finding 1: an attempt whose body answers ExitCode.ok discards its own '
    "frame's recording, so a nested recovery two levels down never "
    "overwrites an enclosing middleware's own recording",
    () {
      test(
        'fail-then-recover: the outer middleware\'s own error, recorded '
        'before it calls a next() that goes on to recover from a deeper '
        'failure, survives that recovery untouched',
        () async {
          final innerError = CommandException(
            id: 'recovered-inner',
            message: 'the handler failed but the inner middleware recovers',
            exitCode: ExitCode.apiError,
          );
          final outerOwnError = CommandException(
            id: 'outer-own-error',
            message:
                'the outer middleware\'s own error, recorded before '
                'recovering',
            exitCode: ExitCode.conflict,
          );

          final result = await _runWith(
            _cliWithNestedRecoveryAndAnOuterErrorRecordedBeforeRecovering(
              innerError,
              outerOwnError,
            ),
            ['widget', '--json'],
          );

          expect(result.exitCode, equals(ExitCode.conflict));
          final envelope = jsonDecode(result.stderr) as Map<String, dynamic>;
          final error = envelope['error'] as Map<String, dynamic>;
          expect(error['id'], equals('outer-own-error'));
          expect(result.stderr, isNot(contains('recovered-inner')));
        },
      );

      test(
        'recover-then-fail: the outer middleware\'s own error, recorded '
        'after a next() call that recovers from a deeper failure, still '
        "renders: a recovered downstream never outranks the outer's own, "
        'later recording either',
        () async {
          final innerError = CommandException(
            id: 'recovered-inner',
            message: 'the handler failed but the inner middleware recovers',
            exitCode: ExitCode.apiError,
          );
          final outerOwnError = CommandException(
            id: 'outer-own-error',
            message:
                'the outer middleware\'s own error, recorded after '
                'recovering',
            exitCode: ExitCode.conflict,
          );

          final result = await _runWith(
            _cliWithNestedRecoveryAndAnOuterErrorRecordedAfterRecovering(
              innerError,
              outerOwnError,
            ),
            ['widget', '--json'],
          );

          expect(result.exitCode, equals(ExitCode.conflict));
          final envelope = jsonDecode(result.stderr) as Map<String, dynamic>;
          final error = envelope['error'] as Map<String, dynamic>;
          expect(error['id'], equals('outer-own-error'));
          expect(result.stderr, isNot(contains('recovered-inner')));
        },
      );
    },
  );

  group(
    'finding 2: a shortcut named help is recognized by the same '
    'name-stripping rule an ordinary route already is, regardless of its '
    "trailing positional's cardinality",
    () {
      test(
        'a shortcut with a required positional (help <topic>) rejects a '
        'missing topic exactly as an ordinary help <topic> route would, '
        'never falling back to the built-in catalog',
        () async {
          final withJson = await _runWith(
            _cliWithARequiredPositionalShortcutNamedHelp(),
            ['help', '--json'],
          );
          expect(withJson.exitCode, equals(ExitCode.invalidUsage));

          final bare = await _runWith(
            _cliWithARequiredPositionalShortcutNamedHelp(),
            [],
          );
          expect(bare.exitCode, equals(ExitCode.invalidUsage));
        },
      );

      test(
        'the same shortcut still dispatches to its target once the '
        'required topic is supplied',
        () async {
          final result = await _runWith(
            _cliWithARequiredPositionalShortcutNamedHelp(),
            ['help', 'something'],
          );

          expect(result.exitCode, equals(ExitCode.ok));
          expect(result.stdout, contains('manual-ran'));
        },
      );

      test(
        'a shortcut with an optional positional (help [<topic>]) still '
        'dispatches to its target on both an explicit and a bare '
        'invocation, exactly as round 13 already established',
        () async {
          final explicit = await _runWith(
            _cliWithAnOptionalPositionalShortcutNamedHelp(),
            ['help'],
          );
          expect(explicit.exitCode, equals(ExitCode.ok));
          expect(explicit.stdout, contains('manual-ran'));

          final bare = await _runWith(
            _cliWithAnOptionalPositionalShortcutNamedHelp(),
            [],
          );
          expect(bare.exitCode, equals(ExitCode.ok));
          expect(bare.stdout, contains('manual-ran'));
        },
      );

      test(
        'a wildcard shortcut (help *) still dispatches to its target on '
        'both an explicit and a bare invocation',
        () async {
          final explicit = await _runWith(
            _cliWithAWildcardShortcutNamedHelp(),
            ['help'],
          );
          expect(explicit.exitCode, equals(ExitCode.ok));
          expect(explicit.stdout, contains('manual-ran'));

          final bare = await _runWith(_cliWithAWildcardShortcutNamedHelp(), []);
          expect(bare.exitCode, equals(ExitCode.ok));
          expect(bare.stdout, contains('manual-ran'));
        },
      );
    },
  );
}
