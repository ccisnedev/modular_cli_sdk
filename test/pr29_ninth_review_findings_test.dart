// Codex round 9 of PR #29 (feat/0.6.0) found four more issues.
//
// Finding 1 (modular_cli.dart, ModularCli.use()): the round-8 fix captures a
// single baseline once, lazily, on the first next() call, and restores it
// whenever a later attempt records nothing of its own. A middleware that
// awaits a first, failing attempt, records an error of its OWN after that
// attempt returns, then awaits a second, silent retry, gets that own error
// erased: the restore reaches back to the pre-attempt-1 baseline, not to
// whatever this middleware most recently recorded itself. The fix keeps two
// independent slots per middleware invocation, `own` (whatever this
// middleware records directly, at any point) and `downstream` (the outcome
// of its latest completed next() attempt, replaced by each new attempt and
// cleared by a silent one), and renders whichever of the two was recorded
// more recently, by a monotonic sequence number
// (InvocationOutcome.recordedAt).
//
// Finding 2 (invocation_outcome.dart, InvocationOutcome.pushFrame /
// popFrame): two overlapping next() calls from the same middleware
// invocation (a second one starting before the first's own next() call has
// completed) share and corrupt the same frame stack. Calling next() again
// while a previous, not yet completed, next() call from the SAME middleware
// invocation is still in flight is a programming error: it must throw a
// StateError naming the middleware's route, not attempt to merge the two.
// Frames stay isolated across separate, unrelated run() calls, as they
// already were.
//
// Findings 3 and 4 (modular_cli.dart, _applicableContractFor(), around
// lines 925 and 927): resolving --help against an unresolved rejection
// dropped candidates two different ways. _contractFor() looked up the
// catalog by name and returned only the first entry found, even when two
// registered routes share the exact same words-only name (`s` and
// `s <id> <sub>` are both named `s`, positionals stripped) and only one of
// them still declares the positional the rejection is actually stuck on.
// Separately, _shortcutContractFor() decided a prefix was ambiguous the
// moment more than one shortcut shared it, before ever checking whether
// only one of them still declares the missing positional. The fix enumerates
// every candidate first, catalog entries and shortcuts alike, then filters
// by the rejection's own missing positional, and only then decides: exactly
// one survivor resolves; zero or more than one keeps the router's own
// rejection.

import 'dart:async';
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
  @override
  Map<String, dynamic> toJson() => {'ok': true};

  @override
  int get exitCode => ExitCode.ok;
}

class _OkQuery implements Query<_WidgetInput, _WidgetOutput> {
  @override
  final _WidgetInput input = _WidgetInput();

  @override
  String? validate() => null;

  @override
  Future<_WidgetOutput> execute() async => _WidgetOutput();
}

/// Throws [firstError] on the first call only; every call after that
/// succeeds silently.
class _FailsOnFirstCallOnlyQuery implements Query<_WidgetInput, _WidgetOutput> {
  _FailsOnFirstCallOnlyQuery(this.state, this.firstError);

  final _RetryState state;
  final CommandException firstError;

  @override
  final _WidgetInput input = _WidgetInput();

  @override
  String? validate() => null;

  @override
  Future<_WidgetOutput> execute() async {
    state.calls++;
    if (state.calls == 1) throw firstError;
    return _WidgetOutput();
  }
}

class _RetryState {
  int calls = 0;
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

/// Awaits a first attempt, discards whatever it returned, records [ownError]
/// directly (never a throw) strictly BETWEEN the two attempts, then awaits a
/// second, silent attempt and returns [ownError.exitCode] regardless of how
/// that second attempt went: the round-9 scenario a lazily captured baseline
/// gets wrong, since the baseline was locked in before this recording ever
/// happened.
CliMiddleware _recordsOwnErrorBetweenTwoAttempts(CommandException ownError) =>
    (next) {
      return (req) async {
        await next(req);
        JsonCliOutput(
          stdout: req.stdout,
          stderr: req.stderr,
        ).writeError(ownError);
        await next(req);
        return ownError.exitCode;
      };
    };

ModularCli _cliOwnRecordedBetweenAttemptsSurvivesASilentRetry() {
  final cli = ModularCli(suggestionDistance: 2);
  final state = _RetryState();
  cli.query<_WidgetInput, _WidgetOutput>(
    'widget',
    (req) => _FailsOnFirstCallOnlyQuery(
      state,
      CommandException(
        id: 'first-attempt-superseded',
        message: 'the first attempt failed and was retried',
        exitCode: ExitCode.apiError,
      ),
    ),
    globals: true,
    contract: CliContract.none,
  );
  cli.use(
    _recordsOwnErrorBetweenTwoAttempts(
      CommandException(
        id: 'own-recorded-between-attempts',
        message: 'recorded strictly between the two attempts',
        exitCode: ExitCode.conflict,
      ),
    ),
  );
  return cli;
}

/// Records [ownError] before ANY next() call, then returns exactly what its
/// one and only next() call returns: when that attempt fails and records a
/// downstream error of its own, the downstream error, being the more
/// recently recorded of the two, wins.
CliMiddleware _recordsOwnBeforeFirstAttemptThenReturnsItsResult(
  CommandException ownError,
) => (next) {
  return (req) async {
    JsonCliOutput(stdout: req.stdout, stderr: req.stderr).writeError(ownError);
    return await next(req);
  };
};

ModularCli _cliOwnBeforeFirstAttemptLosesToADownstreamFailure() {
  final cli = ModularCli(suggestionDistance: 2);
  cli.query<_WidgetInput, _WidgetOutput>(
    'widget',
    (req) => throw CommandException(
      id: 'downstream-failed',
      message: 'the handler itself failed',
      exitCode: ExitCode.dataError,
    ),
    globals: true,
    contract: CliContract.none,
  );
  cli.use(
    _recordsOwnBeforeFirstAttemptThenReturnsItsResult(
      CommandException(
        id: 'own-before-first-attempt',
        message: 'recorded before the only attempt',
        exitCode: ExitCode.conflict,
      ),
    ),
  );
  return cli;
}

/// Awaits its one and only next() attempt (which fails and records a
/// downstream error of its own), then records [ownError] directly
/// afterward, and returns [ownError.exitCode]: recorded strictly after the
/// failing attempt, own is the more recent of the two and wins.
CliMiddleware _failsThenRecordsOwnAfterward(CommandException ownError) =>
    (next) {
      return (req) async {
        await next(req);
        JsonCliOutput(
          stdout: req.stdout,
          stderr: req.stderr,
        ).writeError(ownError);
        return ownError.exitCode;
      };
    };

ModularCli _cliOwnRecordedAfterAFailingAttemptWins() {
  final cli = ModularCli(suggestionDistance: 2);
  cli.query<_WidgetInput, _WidgetOutput>(
    'widget',
    (req) => throw CommandException(
      id: 'downstream-failed',
      message: 'the handler itself failed',
      exitCode: ExitCode.dataError,
    ),
    globals: true,
    contract: CliContract.none,
  );
  cli.use(
    _failsThenRecordsOwnAfterward(
      CommandException(
        id: 'own-after-failing-attempt',
        message: 'recorded after the failing attempt',
        exitCode: ExitCode.conflict,
      ),
    ),
  );
  return cli;
}

// ── Finding 2 fixtures ───────────────────────────────────────────────────────

/// Calls next() twice without awaiting the first call before starting the
/// second: a genuine overlap, not a retry.
CliMiddleware _overlapsTwoNextCallsMiddleware() => (next) {
  return (req) async {
    final a = Future.sync(() => next(req));
    final b = Future.sync(() => next(req));
    final results = await Future.wait([a, b]);
    return results.first;
  };
};

ModularCli _cliWithOverlappingNextCalls() {
  final cli = ModularCli(suggestionDistance: 2);
  cli.query<_WidgetInput, _WidgetOutput>(
    'widget',
    (req) => _OkQuery(),
    globals: true,
    contract: CliContract.none,
  );
  cli.use(_overlapsTwoNextCallsMiddleware());
  return cli;
}

// ── Findings 3 and 4 fixtures ────────────────────────────────────────────────

/// Two catalog routes sharing the exact same words-only name `s` (a bare
/// route and a deeper one continuing it with two positionals), plus a
/// shortcut one level deeper still, `s <id> <sub> <tail>`, targeting a
/// separate `deep <id> <sub> <tail>` route registered purely to give the
/// shortcut something to point at.
ModularCli _cliWithBareAndDeeperRouteSharingAName() {
  final cli = ModularCli(suggestionDistance: 2);
  cli.query<_WidgetInput, _WidgetOutput>(
    's',
    (req) => _OkQuery(),
    globals: true,
    contract: CliContract.none,
  );
  cli.query<_WidgetInput, _WidgetOutput>(
    's <id> <sub>',
    (req) => _OkQuery(),
    globals: true,
    contract: CliContract(
      positionals: [
        CliPositional.string('id', required: true),
        CliPositional.string('sub', required: true),
      ],
    ),
  );
  cli.query<_WidgetInput, _WidgetOutput>(
    'deep <id> <sub> <tail>',
    (req) => _OkQuery(),
    globals: true,
    contract: CliContract(
      positionals: [
        CliPositional.string('id', required: true),
        CliPositional.string('sub', required: true),
        CliPositional.string('tail', required: true),
      ],
    ),
  );
  cli.shortcut(
    's <id> <sub> <tail>',
    target: 'deep',
    globals: true,
    contract: CliContract.none,
  );
  return cli;
}

/// Two shortcuts sharing the exact same literal-words prefix `s`: a bare
/// one and one two positionals deeper, each targeting its own, distinct,
/// separately registered route.
ModularCli _cliWithTwoShortcutsSharingAPrefix() {
  final cli = ModularCli(suggestionDistance: 2);
  cli.query<_WidgetInput, _WidgetOutput>(
    'bare-target',
    (req) => _OkQuery(),
    globals: true,
    contract: CliContract.none,
  );
  cli.query<_WidgetInput, _WidgetOutput>(
    'deep-target <id> <sub>',
    (req) => _OkQuery(),
    globals: true,
    contract: CliContract(
      positionals: [
        CliPositional.string('id', required: true),
        CliPositional.string('sub', required: true),
      ],
    ),
  );
  cli.shortcut(
    's',
    target: 'bare-target',
    globals: true,
    contract: CliContract.none,
  );
  cli.shortcut(
    's <id> <sub>',
    target: 'deep-target',
    globals: true,
    contract: CliContract.none,
  );
  return cli;
}

void main() {
  group('finding 1: a middleware keeps its own recordings and its latest '
      "downstream attempt's outcome as two independent slots, rendering "
      'whichever was recorded more recently', () {
    test('own, recorded strictly between two attempts, survives a silent '
        'retry that follows it', () async {
      final result = await _runWith(
        _cliOwnRecordedBetweenAttemptsSurvivesASilentRetry(),
        ['widget', '--json'],
      );

      expect(result.exitCode, equals(ExitCode.conflict));
      final envelope = jsonDecode(result.stderr) as Map<String, dynamic>;
      final error = envelope['error'] as Map<String, dynamic>;
      expect(error['id'], equals('own-recorded-between-attempts'));
      expect(result.stderr, isNot(contains('first-attempt-superseded')));
    });

    test('own, recorded before the only attempt, loses to that attempt '
        'failing and recording its own downstream error', () async {
      final result = await _runWith(
        _cliOwnBeforeFirstAttemptLosesToADownstreamFailure(),
        ['widget', '--json'],
      );

      expect(result.exitCode, equals(ExitCode.dataError));
      final envelope = jsonDecode(result.stderr) as Map<String, dynamic>;
      final error = envelope['error'] as Map<String, dynamic>;
      expect(error['id'], equals('downstream-failed'));
      expect(result.stderr, isNot(contains('own-before-first-attempt')));
    });

    test('own, recorded strictly after a failing attempt, wins over that '
        "attempt's own downstream error", () async {
      final result = await _runWith(
        _cliOwnRecordedAfterAFailingAttemptWins(),
        ['widget', '--json'],
      );

      expect(result.exitCode, equals(ExitCode.conflict));
      final envelope = jsonDecode(result.stderr) as Map<String, dynamic>;
      final error = envelope['error'] as Map<String, dynamic>;
      expect(error['id'], equals('own-after-failing-attempt'));
      expect(result.stderr, isNot(contains('downstream-failed')));
    });
  });

  group('finding 2: overlapping next() calls from the same middleware '
      'invocation are a programming error', () {
    test('a middleware that calls next() twice without awaiting the first '
        'call throws a StateError naming the route, never merges the two', () async {
      final out = MemorySink();
      final err = MemorySink();

      await expectLater(
        () => _cliWithOverlappingNextCalls().run(
          ['widget'],
          stdout: out,
          stderr: err,
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('widget'),
          ),
        ),
      );
    });
  });

  group('finding 3: --help resolution enumerates every catalog candidate '
      'sharing a name, not just the first one registered', () {
    test('a bare route and a deeper one sharing the name "s", plus a '
        'shortcut one level deeper still, all remain viable at the missing '
        "second positional: the router's own rejection is kept, never a "
        'guessed success', () async {
      final result = await _runWith(
        _cliWithBareAndDeeperRouteSharingAName(),
        ['s', '--json', '--help', '7'],
      );

      expect(result.exitCode, isNot(equals(ExitCode.ok)));
      expect(result.stdout, isEmpty);

      // Round-10 review finding 3: the same ambiguity must also reach the
      // rejection's own stderr envelope, not only --help's success path
      // above. Before the fix, _emitRejectionError() asked the old
      // _contractFor() helper directly, which looked the consumed words
      // ("s") up in the catalog and returned only the first entry
      // registered under that name: the bare `s` route, no positionals at
      // all, even though the rejection is genuinely ambiguous between it
      // and `s <id> <sub>`. That attached the bare route's own (empty)
      // contract to this error, and, since a text-mode envelope renders
      // "you were one flag away" help text from whatever contract it was
      // handed, it would offer the bare `s` route's help even though the
      // invocation was never actually one flag away from it.
      expect(result.exitCode, equals(ExitCode.invalidUsage));
      final envelope = jsonDecode(result.stderr) as Map<String, dynamic>;
      final error = envelope['error'] as Map<String, dynamic>;
      expect(error['id'], equals('missing-argument'));
      expect(error['exitCode'], equals(ExitCode.invalidUsage));
      expect(
        error.containsKey('contract'),
        isFalse,
        reason: 'an ambiguous rejection must never attach any contract, '
            'the unrelated bare "s" one least of all',
      );
    });
  });

  group('finding 4: shortcut ambiguity is decided only after filtering by '
      'the missing positional, not before', () {
    test('two shortcuts sharing the prefix "s", only one of which still '
        'declares the missing second positional, resolve unambiguously to '
        "that one shortcut's own help", () async {
      final result = await _runWith(
        _cliWithTwoShortcutsSharingAPrefix(),
        ['s', '--json', '--help', '7'],
      );

      expect(result.exitCode, equals(ExitCode.ok));
      final envelope = jsonDecode(result.stdout) as Map<String, dynamic>;
      expect(envelope['route'], equals('s <id> <sub>'));
    });
  });
}
