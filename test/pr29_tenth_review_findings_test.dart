// Codex round 10 of PR #29 (feat/0.6.0) found three more issues.
//
// Finding 1 (invocation_outcome.dart, modular_cli.dart's ModularCli.use()):
// round-9's fix keeps two slots, `own` and `downstream`, but both still live
// on the SAME shared [InvocationOutcome] frame stack, addressed only by
// whichever frame happens to be on top of that stack at the moment a write
// occurs. A middleware that starts `pending = next(req)` without awaiting it,
// records its own error directly while that call is still suspended
// (downstream's frame is the one on top right then, since it was pushed
// before `next()` itself ever runs the actual dispatch), then awaits
// `pending`, then retries silently: the own recording lands in the pushed
// downstream frame, not a frame of its own, and a later, silent, successful
// retry (whose own fresh frame folds back "nothing recorded", which the old
// `applyWinner()` treated as authoritative once `downSeq` reset to 0) wipes
// it out, rendering no envelope at all even though the middleware returned
// its own nonzero exit code.
//
// The fix (invocation_outcome.dart's `InvocationOutcome.runAttempt`,
// `modular_cli.dart`'s rewritten `use()`) addresses recordings by the
// asynchronous execution context a write actually runs in, not by whichever
// frame a shared, mutable stack happens to have on top: each `next()`
// attempt runs downstream inside a child [Zone] carrying that attempt's own
// frame, and every recording path resolves the frame to write into by
// walking up from `Zone.current`, so a write made from the middleware's own
// synchronous continuation (never inside that child zone) always lands in
// the middleware's own, separate frame, however the two are interleaved in
// time. There is no "topmost frame" lookup left to get this wrong.
//
// Finding 2 (modular_cli.dart, `_applicableContractFor`,
// `CommandCatalog.allForName`): a route with no literal words at all, only
// positionals (`<id> <sub>`, mounted at the CLI's own root), is registered
// under the empty name. A shortcut one positional deeper, sharing that same
// empty prefix (`<id> <sub> <tail>`), is a genuine ambiguity at the same
// missing positional this catalog route and the shortcut disagree on. Before
// the fix, [CommandCatalog.allForName] was only ever asked for a NON-empty
// consumed prefix (guarded by `consumed.isNotEmpty`), so this catalog route
// was silently dropped from the candidate list while the shortcut sharing
// the same empty prefix was still included unconditionally: a genuinely
// ambiguous rejection resolved to the shortcut's own help, granted with exit
// code 0, instead of the router's own rejection.
//
// Finding 3 (modular_cli.dart, `_emitRejectionError`): covered by an
// extension to the existing ambiguity test in
// `pr29_ninth_review_findings_test.dart` (finding 3's group), asserting the
// full stderr envelope now that `_emitRejectionError` goes through the same
// unified, ambiguity-aware `_unambiguousContractFor` resolution `--help`
// already used, rather than the old `_contractFor` (since deleted), which
// attached whichever catalog entry it found first even when genuinely
// ambiguous.

import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;

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

class _RetryState {
  int calls = 0;
}

/// Suspends on [gate] on its first call only, before failing with
/// [firstError]; every call after that succeeds silently and immediately.
/// The suspension is what gives a test a deterministic window in which the
/// first attempt is genuinely still in flight (its own dispatch-level frame
/// still open) when other code runs concurrently with it.
class _SuspendsThenFailsFirstCallQuery
    implements Query<_WidgetInput, _WidgetOutput> {
  _SuspendsThenFailsFirstCallQuery(this.state, this.gate, this.firstError);

  final _RetryState state;
  final Completer<void> gate;
  final CommandException firstError;

  @override
  final _WidgetInput input = _WidgetInput();

  @override
  String? validate() => null;

  @override
  Future<_WidgetOutput> execute() async {
    state.calls++;
    if (state.calls == 1) {
      await gate.future;
      throw firstError;
    }
    return _WidgetOutput();
  }
}

/// Starts a first attempt without awaiting it, records [ownError] directly
/// while that attempt is still suspended (its own frame, in the pre-round-10
/// design, would be the one on top of the shared stack right then), releases
/// it, awaits it (it fails), then retries once, silently, and returns
/// [ownError.exitCode] regardless of how the retry went: exactly the round-10
/// finding 1 scenario.
CliMiddleware _recordsOwnWhileFirstAttemptIsSuspendedThenSilentlyRetries(
  CommandException ownError,
  Completer<void> gate,
) => (next) {
  return (req) async {
    final pending = next(req);
    JsonCliOutput(
      stdout: req.stdout,
      stderr: req.stderr,
    ).writeError(ownError);
    gate.complete();
    await pending;
    await next(req);
    return ownError.exitCode;
  };
};

ModularCli _cliOwnRecordedWhileFirstAttemptSuspendedSurvivesASilentRetry(
  _RetryState state,
  Completer<void> gate,
) {
  final cli = ModularCli(suggestionDistance: 2);
  cli.query<_WidgetInput, _WidgetOutput>(
    'widget',
    (req) => _SuspendsThenFailsFirstCallQuery(
      state,
      gate,
      CommandException(
        id: 'first-attempt-suspended-then-superseded',
        message: 'the first attempt was still suspended when own recorded '
            'over it, then was superseded by a silent retry',
        exitCode: ExitCode.apiError,
      ),
    ),
    globals: true,
    contract: CliContract.none,
  );
  cli.use(
    _recordsOwnWhileFirstAttemptIsSuspendedThenSilentlyRetries(
      CommandException(
        id: 'own-recorded-while-first-attempt-suspended',
        message: 'recorded while the first attempt was still in flight, '
            'concurrently',
        exitCode: ExitCode.conflict,
      ),
      gate,
    ),
  );
  return cli;
}

/// On its first call only: records [midFlightError] directly (simulating a
/// downstream boundary that records mid-dispatch, the way an approval
/// refusal or a failed step does, per `recordInvocationError`'s own doc
/// comment, rather than only ever recording by eventually throwing), then
/// suspends on [gate], then returns *successfully*. Every call after the
/// first skips all of that and returns successfully right away, recording
/// nothing: exactly the silent retry finding 1 describes.
class _RecordsMidFlightThenSucceedsOnFirstCallOnlyQuery
    implements Query<_WidgetInput, _WidgetOutput> {
  _RecordsMidFlightThenSucceedsOnFirstCallOnlyQuery(
    this.state,
    this.stdout,
    this.stderr,
    this.gate,
    this.midFlightError,
  );

  final _RetryState state;
  final io.IOSink stdout;
  final io.IOSink stderr;
  final Completer<void> gate;
  final CommandException midFlightError;

  @override
  final _WidgetInput input = _WidgetInput();

  @override
  String? validate() => null;

  @override
  Future<_WidgetOutput> execute() async {
    state.calls++;
    if (state.calls == 1) {
      JsonCliOutput(stdout: stdout, stderr: stderr).writeError(midFlightError);
      await gate.future;
    }
    return _WidgetOutput();
  }
}

/// Starts the first attempt without awaiting it (letting it record
/// [midFlightError] mid-dispatch, then suspend on [gate]), records
/// [ownError] directly right after that — still genuinely concurrent: the
/// first attempt is still suspended, its own mid-flight recording already
/// made — then releases it, awaits it (it succeeds), and finally retries
/// once, silently, returning [ownError.exitCode] regardless of how the
/// retry went. Both downstream's mid-flight recording and own's recording
/// happen while overlapping in time; only own's, the one still standing
/// once the attempt it was concurrent with finishes, should survive the
/// silent retry that follows.
CliMiddleware
_recordsOwnRightAfterDownstreamRecordsMidFlightThenSilentlyRetries(
  CommandException ownError,
  Completer<void> gate,
) => (next) {
  return (req) async {
    final pending = next(req);
    JsonCliOutput(
      stdout: req.stdout,
      stderr: req.stderr,
    ).writeError(ownError);
    gate.complete();
    await pending;
    await next(req);
    return ownError.exitCode;
  };
};

ModularCli _cliOwnRecordedRightAfterDownstreamsMidFlightRecordSurvivesRetry(
  _RetryState state,
  Completer<void> gate,
) {
  final cli = ModularCli(suggestionDistance: 2);
  cli.query<_WidgetInput, _WidgetOutput>(
    'widget',
    (req) => _RecordsMidFlightThenSucceedsOnFirstCallOnlyQuery(
      state,
      req.stdout,
      req.stderr,
      gate,
      CommandException(
        id: 'downstream-recorded-mid-flight-then-superseded',
        message: 'downstream recorded mid-dispatch, concurrently with own, '
            'then was itself superseded by a silent retry',
        exitCode: ExitCode.dataError,
      ),
    ),
    globals: true,
    contract: CliContract.none,
  );
  cli.use(
    _recordsOwnRightAfterDownstreamRecordsMidFlightThenSilentlyRetries(
      CommandException(
        id: 'own-recorded-concurrently-with-downstreams-mid-flight-record',
        message: 'recorded while downstream, having just recorded its own '
            'mid-flight error, was still suspended',
        exitCode: ExitCode.conflict,
      ),
      gate,
    ),
  );
  return cli;
}

// ── Finding 2 fixtures ───────────────────────────────────────────────────────

/// A catalog route with no literal words at all (`<id> <sub>`, mounted at the
/// CLI's own root) alongside a shortcut one positional deeper still sharing
/// that same empty prefix (`<id> <sub> <tail>`), targeting a separate `deep`
/// route registered purely to give the shortcut something to point at.
/// Mirrors `_cliWithBareAndDeeperRouteSharingAName` in
/// `pr29_ninth_review_findings_test.dart`, but with the shared name empty
/// rather than `s`, so `CliRejection.consumed` is empty at the rejection
/// this ambiguity produces.
ModularCli _cliWithRootPositionalOnlyRouteAndDeeperShortcutSharingEmptyPrefix() {
  final cli = ModularCli(suggestionDistance: 2);
  cli.query<_WidgetInput, _WidgetOutput>(
    '<id> <sub>',
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
    '<id> <sub> <tail>',
    target: 'deep',
    globals: true,
    contract: CliContract.none,
  );
  return cli;
}

void main() {
  group('finding 1: a middleware\'s own recordings and its next() attempts\' '
      'outcomes are addressed by the zone a write actually runs in, never '
      "by whichever frame a shared stack happens to have on top, so timing "
      "can never misattribute one for the other", () {
    test('own, recorded while the first attempt is still suspended '
        '(genuinely concurrent with it, not merely sequenced after it '
        'completes), survives a silent retry that follows', () async {
      final result = await _runWith(
        _cliOwnRecordedWhileFirstAttemptSuspendedSurvivesASilentRetry(
          _RetryState(),
          Completer<void>(),
        ),
        ['widget', '--json'],
      );

      expect(result.exitCode, equals(ExitCode.conflict));
      final envelope = jsonDecode(result.stderr) as Map<String, dynamic>;
      final error = envelope['error'] as Map<String, dynamic>;
      expect(error['id'], equals('own-recorded-while-first-attempt-suspended'));
      expect(
        result.stderr,
        isNot(contains('first-attempt-suspended-then-superseded')),
      );
    });

    test('downstream records mid-dispatch (not only by eventually throwing) '
        'while own also records, genuinely concurrently (downstream is '
        'still suspended right after its own mid-flight recording); both '
        'stay in their own slots, and own, the one still standing once a '
        'silent retry supersedes downstream\'s superseded attempt, is '
        'rendered', () async {
      final result = await _runWith(
        _cliOwnRecordedRightAfterDownstreamsMidFlightRecordSurvivesRetry(
          _RetryState(),
          Completer<void>(),
        ),
        ['widget', '--json'],
      );

      expect(result.exitCode, equals(ExitCode.conflict));
      final envelope = jsonDecode(result.stderr) as Map<String, dynamic>;
      final error = envelope['error'] as Map<String, dynamic>;
      expect(
        error['id'],
        equals('own-recorded-concurrently-with-downstreams-mid-flight-record'),
      );
      expect(
        result.stderr,
        isNot(contains('downstream-recorded-mid-flight-then-superseded')),
      );
    });
  });

  group('finding 2: CommandCatalog.allForName is asked for the empty prefix '
      'too, exactly like any other, so a root positional-only route is '
      'never silently dropped from the candidate list', () {
    test('a root positional-only catalog route and a shortcut one '
        'positional deeper, sharing the same empty prefix, are genuinely '
        "ambiguous at the missing third positional: the router's own "
        'rejection is kept, never the shortcut\'s help granted with exit '
        'code 0', () async {
      final result = await _runWith(
        _cliWithRootPositionalOnlyRouteAndDeeperShortcutSharingEmptyPrefix(),
        ['--json', '--help', '7'],
      );

      expect(result.exitCode, isNot(equals(ExitCode.ok)));
      expect(result.stdout, isEmpty);
    });
  });
}
