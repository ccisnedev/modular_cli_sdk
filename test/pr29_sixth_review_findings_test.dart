// Codex round 6 of PR #29 (feat/0.6.0) found the previous per-boundary
// patches (round 5) still missing cases.
//
// Part A, error rendering (findings 1-3): a query's own thrown
// CommandException was already written by ModuleBuilder._reject() before
// an outer middleware that escalated a nonzero result got its own throw
// written too (finding 1, and the same double write for an approval
// refusal and a failed step); an inner failure an outer middleware went on
// to recover from, or a retry that went on to succeed, still rendered the
// stale error even though the invocation finished at exit 0 (finding 2);
// and the pending error lived on ModularCli itself as an instance field,
// so a recursive `cli.run()` call (a handler that calls it again with its
// own sinks) or two concurrent `run()` calls on the same instance leaked or
// cleared each other's error (finding 3).
//
// Part B, shortcut contract lookup (findings 4-6): a shortcut's
// literal-prefix key could overwrite a different shortcut's exact key
// registered at the same words (finding 4); a shortcut with no literal
// words at all (a bare `<id>` mounted under a module) registered its
// prefix key with a trailing space cli_router's own rejection never asks
// for, and an empty prefix (the same shortcut at the root) was never even
// looked up, since the lookup returned early on empty `consumed` before
// consulting the map (finding 5); and a resolved shortcut mounted under a
// module rendered its own `--help` with the bare, unmounted pattern
// instead of the full mounted route (finding 6).
//
// Findings are numbered to match that round, 1 through 6.

import 'dart:async';
import 'dart:convert';

import 'package:cli_router/cli_router.dart' show CliMiddleware;
import 'package:modular_cli_sdk/modular_cli_sdk.dart';
import 'package:test/test.dart';

import 'doubles.dart';

// ── Shared query fixtures ───────────────────────────────────────────────

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

/// A query that always throws [error] from execute().
class _ThrowingQuery implements Query<_WidgetInput, _WidgetOutput> {
  _ThrowingQuery(this.error);

  final CommandException error;

  @override
  final _WidgetInput input = _WidgetInput();

  @override
  String? validate() => null;

  @override
  Future<_WidgetOutput> execute() async {
    throw error;
  }
}

class _FlakyState {
  int calls = 0;
}

/// A query that throws on its first call and succeeds on every call after,
/// for a middleware that retries.
class _FlakyQuery implements Query<_WidgetInput, _WidgetOutput> {
  _FlakyQuery(this.state);

  final _FlakyState state;

  @override
  final _WidgetInput input = _WidgetInput();

  @override
  String? validate() => null;

  @override
  Future<_WidgetOutput> execute() async {
    state.calls++;
    if (state.calls == 1) {
      throw CommandException(
        id: 'flaky-first-call',
        message: 'the first call always fails',
        exitCode: ExitCode.apiError,
      );
    }
    return _WidgetOutput();
  }
}

class _RecursiveCapture {
  int? innerExitCode;
  String? innerStderr;
}

/// A query that calls `cli.run()` again, with its own sinks, for a route
/// that fails there, and then completes successfully itself. The point is
/// the *outer* call: it does no throwing of its own, so nothing about its
/// own dispatch should record or render any error at all, regardless of
/// what the nested call recorded and already rendered into its own sinks.
class _RecursiveRunQuery implements Query<_WidgetInput, _WidgetOutput> {
  _RecursiveRunQuery(this.cli, this.capture);

  final ModularCli cli;
  final _RecursiveCapture capture;

  @override
  final _WidgetInput input = _WidgetInput();

  @override
  String? validate() => null;

  @override
  Future<_WidgetOutput> execute() async {
    final innerErr = MemorySink();
    final innerCode = await cli.run(
      ['inner-fail', '--json'],
      stdout: MemorySink(),
      stderr: innerErr,
    );
    capture.innerExitCode = innerCode;
    capture.innerStderr = innerErr.output;
    return _WidgetOutput();
  }
}

// ── Part A fixtures ──────────────────────────────────────────────────────

/// Registered first: outermost. Runs `next` and, seeing a nonzero result,
/// escalates it into its own thrown CommandException.
CliMiddleware _escalatingMiddleware() => (next) {
  return (req) async {
    final result = await next(req);
    if (result != 0) {
      throw CommandException(
        id: 'outer-escalated-the-failure',
        message: 'the outer middleware escalated a nonzero result',
        exitCode: ExitCode.conflict,
      );
    }
    return result;
  };
};

/// Like [_escalatingMiddleware], but tags the escalated error's id with the
/// route word that was actually invoked, so a test with more than one
/// failing route through the same middleware can tell which call's error
/// it is looking at.
CliMiddleware _escalatingMiddlewareTaggedByRoute() => (next) {
  return (req) async {
    final result = await next(req);
    if (result != 0) {
      final tag = req.originalArgs.isNotEmpty
          ? req.originalArgs.first
          : 'unknown';
      throw CommandException(
        id: 'escalated-$tag',
        message: 'the outer middleware escalated a nonzero result for $tag',
        exitCode: ExitCode.conflict,
      );
    }
    return result;
  };
};

ModularCli _cliQueryThrowsWithEscalatingMiddleware() {
  final cli = ModularCli(suggestionDistance: 2);
  cli.query<_WidgetInput, _WidgetOutput>(
    'widget',
    (req) => _ThrowingQuery(
      CommandException(
        id: 'widget-query-broke',
        message: 'the widget query threw on its own',
        exitCode: ExitCode.notFound,
      ),
    ),
    globals: true,
    contract: CliContract.none,
    description: 'A query that always throws',
  );
  cli.use(_escalatingMiddleware());
  return cli;
}

ModularCli _cliApprovalRefusedWithEscalatingMiddleware() {
  final cli = ModularCli(
    suggestionDistance: 2,
    approver: (_) async => false,
  );
  cli.command<TouchInput, TouchOutput>(
    'touch',
    (req) => TouchCommand(TouchInput()),
    globals: true,
    contract: CliContract.none,
    description: 'Touch things',
  );
  cli.use(_escalatingMiddleware());
  return cli;
}

ModularCli _cliStepFailedWithEscalatingMiddleware() {
  final cli = ModularCli(suggestionDistance: 2);
  cli.command<TouchInput, TouchOutput>(
    'touch',
    (req) => TouchCommand(
      TouchInput(),
      error: CommandException(
        id: 'disk-full',
        message: 'no space left on device',
        exitCode: ExitCode.dataError,
      ),
    ),
    globals: true,
    contract: CliContract.none,
    description: 'Touch things',
  );
  cli.use(_escalatingMiddleware());
  return cli;
}

ModularCli _cliInnerFailureRecoveredByOuter() {
  final cli = ModularCli(suggestionDistance: 2);
  cli.query<_WidgetInput, _WidgetOutput>(
    'widget',
    (req) => _ThrowingQuery(
      CommandException(
        id: 'widget-query-broke',
        message: 'the widget query threw on its own',
        exitCode: ExitCode.notFound,
      ),
    ),
    globals: true,
    contract: CliContract.none,
  );
  // Outermost: swallows whatever the inner chain returned.
  cli.use((next) {
    return (req) async {
      await next(req);
      return 0;
    };
  });
  return cli;
}

ModularCli _cliRetryThatSucceeds(_FlakyState state) {
  final cli = ModularCli(suggestionDistance: 2);
  cli.query<_WidgetInput, _WidgetOutput>(
    'widget',
    (req) => _FlakyQuery(state),
    globals: true,
    contract: CliContract.none,
  );
  cli.use((next) {
    return (req) async {
      var result = await next(req);
      if (result != 0) {
        result = await next(req);
      }
      return result;
    };
  });
  return cli;
}

/// A CLI with an escalating middleware wired globally (the only thing that
/// ever touches the pending-error state), so a nested `cli.run()` call
/// through the `inner-fail` route exercises the exact mechanism finding 3
/// is about: the outer route's own dispatch goes through that same
/// middleware, and, since it does not itself throw, nothing about its own
/// dispatch should touch whatever the nested call already recorded and
/// rendered for itself.
ModularCli _cliForRecursiveRun(_RecursiveCapture capture) {
  final cli = ModularCli(suggestionDistance: 2);
  cli.query<_WidgetInput, _WidgetOutput>(
    'inner-fail',
    (req) => _ThrowingQuery(
      CommandException(
        id: 'inner-run-failed',
        message: 'the inner run failed',
        exitCode: ExitCode.dataError,
      ),
    ),
    globals: true,
    contract: CliContract.none,
  );
  cli.query<_WidgetInput, _WidgetOutput>(
    'outer',
    (req) => _RecursiveRunQuery(cli, capture),
    globals: true,
    contract: CliContract.none,
  );
  cli.use(_escalatingMiddlewareTaggedByRoute());
  return cli;
}

/// A query that calls `cli.run()` again, which *succeeds* this time, and
/// only then throws its own [CommandException]: round-7 review finding 3's
/// recursion case, the mirror image of [_RecursiveRunQuery] above. The
/// point is the opposite one: a nested call that finishes cleanly, touching
/// its own zone's [InvocationOutcome] along the way (including the
/// per-attempt reset round-7 finding 1 adds), must not disturb whatever the
/// parent's own zone already holds, or goes on to record, once control
/// returns to it.
class _RecursiveThenFailsQuery implements Query<_WidgetInput, _WidgetOutput> {
  _RecursiveThenFailsQuery(this.cli, this.capture, {required this.ownError});

  final ModularCli cli;
  final _RecursiveCapture capture;
  final CommandException ownError;

  @override
  final _WidgetInput input = _WidgetInput();

  @override
  String? validate() => null;

  @override
  Future<_WidgetOutput> execute() async {
    final innerOut = MemorySink();
    final innerErr = MemorySink();
    final innerCode = await cli.run(
      ['inner-ok', '--json'],
      stdout: innerOut,
      stderr: innerErr,
    );
    capture.innerExitCode = innerCode;
    capture.innerStderr = innerErr.output;
    throw ownError;
  }
}

/// A CLI whose `outer-fails` route calls a nested, successful `cli.run()`
/// call before throwing its own error: the exact shape round-7 review
/// finding 3 asks for ("the parent records a failure, calls a nested
/// run() that succeeds, then returns nonzero").
ModularCli _cliForRecursiveRunThatSucceedsThenParentFails(
  _RecursiveCapture capture,
) {
  final cli = ModularCli(suggestionDistance: 2);
  cli.query<_WidgetInput, _WidgetOutput>(
    'inner-ok',
    (req) => _OkQuery(),
    globals: true,
    contract: CliContract.none,
  );
  cli.query<_WidgetInput, _WidgetOutput>(
    'outer-fails',
    (req) => _RecursiveThenFailsQuery(
      cli,
      capture,
      ownError: CommandException(
        id: 'outer-failed-after-successful-nested-run',
        message: "the outer query's own work failed, after its nested run "
            'had already succeeded',
        exitCode: ExitCode.dataError,
      ),
    ),
    globals: true,
    contract: CliContract.none,
  );
  return cli;
}

/// Registered globally on the same [ModularCli] whose `outer-preserves`
/// route it also runs behind: only for that one route (tagged by
/// [CliRequest.originalArgs]'s first word, the same gating
/// [_escalatingMiddlewareTaggedByRoute] and [_barrierAfterMiddleware] below
/// use, since this middleware is global and therefore also runs behind the
/// *nested* `inner-ok` call on the same instance) does it record [ownError]
/// directly, via [JsonCliOutput.writeError] rather than a throw, before the
/// nested run() call even starts, run that nested call to a successful
/// finish, and then return [ownError.exitCode] itself, unchanged, without
/// ever recording anything a second time: round-8 review finding 4's own
/// recursion scenario, distinct from [_RecursiveThenFailsQuery] above
/// (which throws a *fresh* error only after its nested call has already
/// returned). The point here is whether the nested run(), which pushes and
/// pops its own frames and touches its own zone's InvocationOutcome along
/// the way, can disturb an error the parent already recorded before it
/// even started, or the parent's own next() call for its own leaf handler
/// (which pushes a frame of its own) can wipe that same pre-recorded
/// error out from under it.
CliMiddleware _recordsOwnErrorThenRunsNestedSuccessfullyTaggedByRoute(
  ModularCli cli,
  _RecursiveCapture capture,
  CommandException ownError,
) => (next) {
  return (req) async {
    final tag = req.originalArgs.isNotEmpty ? req.originalArgs.first : '';
    if (tag != 'outer-preserves') {
      return await next(req);
    }

    JsonCliOutput(stdout: req.stdout, stderr: req.stderr).writeError(ownError);

    final innerOut = MemorySink();
    final innerErr = MemorySink();
    final innerCode = await cli.run(
      ['inner-ok', '--json'],
      stdout: innerOut,
      stderr: innerErr,
    );
    capture.innerExitCode = innerCode;
    capture.innerStderr = innerErr.output;

    await next(req);
    return ownError.exitCode;
  };
};

/// A CLI whose `outer-preserves` route's own global middleware records its
/// error before running a nested, successful cli.run() call on the same
/// instance, then returns the original nonzero code directly, without
/// re-recording: round-8 review finding 4's exact scenario.
ModularCli _cliForRecursiveRunPreservingParentErrorRecordedFirst(
  _RecursiveCapture capture,
) {
  final cli = ModularCli(suggestionDistance: 2);
  cli.query<_WidgetInput, _WidgetOutput>(
    'inner-ok',
    (req) => _OkQuery(),
    globals: true,
    contract: CliContract.none,
  );
  cli.query<_WidgetInput, _WidgetOutput>(
    'outer-preserves',
    (req) => _OkQuery(),
    globals: true,
    contract: CliContract.none,
  );
  cli.use(
    _recordsOwnErrorThenRunsNestedSuccessfullyTaggedByRoute(
      cli,
      capture,
      CommandException(
        id: 'outer-error-recorded-before-nested-run',
        message: "the outer's own error, recorded before its nested run() "
            'call even started',
        exitCode: ExitCode.dataError,
      ),
    ),
  );
  return cli;
}

/// Wraps `next` and, only for the request whose first argument is
/// [routeWord], awaits [barrier] *after* `next` has already returned: by
/// the time this suspends, whatever `next` itself threw has already been
/// caught and recorded by an inner boundary, so what this holds is the
/// gap between "the error is fully recorded" and "run() reads it back and
/// renders it: the exact gap round-7 review finding 3 asks a test to
/// force open with an explicit barrier, rather than relying on
/// `Duration.zero` delays and hoping the scheduler interleaves the two
/// `run()` calls the way the test wants.
///
/// Round-8 review finding 4: completes [reached], if given, the instant
/// this dispatch is about to park on [barrier], so a test can `await` that
/// acknowledgement before starting the second `run()` call instead of
/// relying on the first `run()` call, merely having been started but not
/// yet awaited, to have already reached this exact point by the time the
/// second call begins. Ordering the two calls that way is an assumption
/// about how far an unawaited `Future` happens to run before the test's
/// own code resumes; [reached] replaces that assumption with an explicit
/// signal.
CliMiddleware _barrierAfterMiddleware(
  String routeWord,
  Completer<void> barrier, {
  Completer<void>? reached,
}) => (next) {
  return (req) async {
    final result = await next(req);
    final tag = req.originalArgs.isNotEmpty ? req.originalArgs.first : '';
    if (tag == routeWord) {
      reached?.complete();
      await barrier.future;
    }
    return result;
  };
};

/// The same two failing routes as [_cliForConcurrentRuns], but `fail-a`'s
/// own dispatch is held, after its error is fully recorded and before
/// `run()` renders it, on [barrierA]: a test drives `fail-b`'s `run()` call
/// to full completion first, then releases [barrierA] and drives `fail-a`'s
/// to completion, to prove each renders only its own error even though
/// `fail-b` ran to completion, on the same [ModularCli] instance, entirely
/// while `fail-a` was suspended mid-dispatch.
///
/// [reachedBarrierA], if given, is threaded straight through to
/// [_barrierAfterMiddleware] as its own `reached` acknowledgement (round-8
/// review finding 4).
ModularCli _cliForConcurrentRunsWithBarrier(
  Completer<void> barrierA, {
  Completer<void>? reachedBarrierA,
}) {
  final cli = ModularCli(suggestionDistance: 2);
  cli.query<_WidgetInput, _WidgetOutput>(
    'fail-a',
    (req) => _ThrowingQuery(
      CommandException(
        id: 'error-a',
        message: 'A failed',
        exitCode: ExitCode.notFound,
      ),
    ),
    globals: true,
    contract: CliContract.none,
  );
  cli.query<_WidgetInput, _WidgetOutput>(
    'fail-b',
    (req) => _ThrowingQuery(
      CommandException(
        id: 'error-b',
        message: 'B failed',
        exitCode: ExitCode.unauthorized,
      ),
    ),
    globals: true,
    contract: CliContract.none,
  );
  // Outermost: holds fail-a's dispatch after the escalating middleware
  // below has already thrown, been caught and recorded its error.
  cli.use(
    _barrierAfterMiddleware('fail-a', barrierA, reached: reachedBarrierA),
  );
  cli.use(_escalatingMiddlewareTaggedByRoute());
  return cli;
}

// ── Part B fixtures ──────────────────────────────────────────────────────

/// The shortcut's own contract: an optional integer `a` (the bad-typed
/// value each test supplies) and a required string `b`, exactly as review
/// finding 4 describes.
CliContract _integerAContract() => CliContract(
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

/// A second shortcut's own contract, declaring `a` as a *string* instead,
/// so an invocation with a badly typed `--a` validates fine against this
/// one, distinguishing "resolved against the right contract" from "resolved
/// against the wrong one" (review finding 4).
CliContract _stringAContract() => CliContract(
  options: [
    CliParam.string(
      'a',
      abbr: null,
      required: false,
      repeatable: false,
      defaultValue: null,
      description: 'A string this other shortcut declares itself',
    ),
  ],
);

/// Finding 4: a bare literal shortcut `s` (integer `a`, required `b`) and a
/// required-positional shortcut `s <id>` (string `a`) both registered at
/// the root. A single shared key must not let the second overwrite the
/// first's exact entry.
ModularCli _cliWithBareAndPositionalShortcutsSharingAWord() {
  final cli = ModularCli(suggestionDistance: 2);
  cli.query<_WidgetInput, _WidgetOutput>(
    'widget [<id>]',
    (req) => _OkQuery(),
    globals: true,
    contract: CliContract(
      positionals: [CliPositional.string('id', required: false)],
    ),
  );
  cli.shortcut(
    's',
    target: 'widget',
    globals: true,
    contract: _integerAContract(),
  );
  cli.shortcut(
    's <id>',
    target: 'widget',
    globals: true,
    contract: _stringAContract(),
  );
  return cli;
}

/// Finding 5, root: a shortcut with no literal words at all (`<id>` alone),
/// mounted at the root next to another route that gives the root node
/// literal children of its own.
ModularCli _cliWithRootPositionalOnlyShortcut() {
  final cli = ModularCli(suggestionDistance: 2);
  cli.query<_WidgetInput, _WidgetOutput>(
    'widget2 <id>',
    (req) => _OkQuery(),
    globals: true,
    contract: CliContract(
      positionals: [CliPositional.string('id', required: true)],
    ),
  );
  cli.shortcut(
    '<id>',
    target: 'widget2',
    globals: true,
    contract: _integerAContract(),
  );
  return cli;
}

/// Finding 5, mounted: the same positional-only shape, mounted under a
/// module, so its prefix key is the module name alone (`m`), never `m `
/// with a trailing space.
ModularCli _cliWithModuleMountedPositionalOnlyShortcut() {
  final cli = ModularCli(suggestionDistance: 2);
  cli.module('m', (m) {
    m.query<_WidgetInput, _WidgetOutput>(
      'widget2 <id>',
      (req) => _OkQuery(),
      globals: true,
      contract: CliContract(
        positionals: [CliPositional.string('id', required: true)],
      ),
    );
    m.shortcut(
      '<id>',
      target: 'm widget2',
      globals: true,
      contract: _integerAContract(),
    );
  });
  return cli;
}

/// Finding 6: a literal shortcut `s` mounted under module `m`, so it must
/// render its own `--help` (both text and JSON) as `m s`, not the bare `s`
/// it was declared with. No required option of its own: `--help` on a
/// *resolved* invocation is answered by [ModuleBuilder]'s own handler
/// (`entry.toJson()` / `HelpRenderer.renderCommand(entry)`, keyed by the
/// shortcut's own `entry.route`), a different path than a *rejected*
/// invocation's focused help, which by design never shows a shortcut's own
/// contract (round-4 review finding 1) and is not what this finding is
/// about.
ModularCli _cliWithModuleMountedLiteralShortcut() {
  final cli = ModularCli(suggestionDistance: 2);
  cli.query<_WidgetInput, _WidgetOutput>(
    'widget',
    (req) => _OkQuery(),
    globals: true,
    contract: CliContract.none,
  );
  cli.module('m', (m) {
    m.shortcut(
      's',
      target: 'widget',
      globals: true,
      contract: CliContract.none,
    );
  });
  return cli;
}

/// The ambiguous two-candidate case: two shortcuts, `s <id>` and
/// `s <id> <sub>`, share the literal prefix `s` and the required parameter
/// name `id`, so both are simultaneously reachable through
/// `cli_router`'s own param-only walk from the `s` node, with no literal
/// word left to tell them apart. `s --help` (the `id` operand never
/// supplied) cannot be attributed to either one.
ModularCli _cliWithAmbiguousSharedPrefixShortcuts() {
  final cli = ModularCli(suggestionDistance: 2);
  cli.query<_WidgetInput, _WidgetOutput>(
    'widget <id>',
    (req) => _OkQuery(),
    globals: true,
    contract: CliContract(
      positionals: [CliPositional.string('id', required: true)],
    ),
  );
  cli.query<_WidgetInput, _WidgetOutput>(
    'widget2 <id> <sub>',
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
    's <id>',
    target: 'widget',
    globals: true,
    contract: CliContract.none,
  );
  cli.shortcut(
    's <id> <sub>',
    target: 'widget2',
    globals: true,
    contract: CliContract.none,
  );
  return cli;
}

void main() {
  group(
    'finding 1: a handler\'s own thrown error and an outer middleware\'s '
    'escalation must not both be rendered',
    () {
      test('a query that throws, escalated by an outer middleware, writes '
          'stderr as a single JSON document carrying only the outer error', () async {
        final result = await _runWith(
          _cliQueryThrowsWithEscalatingMiddleware(),
          ['widget', '--json'],
        );

        expect(result.exitCode, equals(ExitCode.conflict));
        final envelope = jsonDecode(result.stderr) as Map<String, dynamic>;
        final error = envelope['error'] as Map<String, dynamic>;
        expect(error['id'], equals('outer-escalated-the-failure'));
      });

      test('an approval refusal, escalated by an outer middleware, writes '
          'only the outer error', () async {
        final result = await _runWith(
          _cliApprovalRefusedWithEscalatingMiddleware(),
          ['touch', '--apply', '--json'],
        );

        expect(result.exitCode, equals(ExitCode.conflict));
        final envelope = jsonDecode(result.stderr) as Map<String, dynamic>;
        final error = envelope['error'] as Map<String, dynamic>;
        expect(error['id'], equals('outer-escalated-the-failure'));
        expect(result.stderr, isNot(contains('approval-refused')));
      });

      test('a failed step, escalated by an outer middleware, writes only '
          'the outer error', () async {
        final result = await _runWith(
          _cliStepFailedWithEscalatingMiddleware(),
          ['touch', '--apply', '--autoapprove', '--json'],
        );

        expect(result.exitCode, equals(ExitCode.conflict));
        final envelope = jsonDecode(result.stderr) as Map<String, dynamic>;
        final error = envelope['error'] as Map<String, dynamic>;
        expect(error['id'], equals('outer-escalated-the-failure'));
        expect(result.stderr, isNot(contains('disk-full')));
      });
    },
  );

  group(
    'finding 2: a recorded error must not be rendered once the invocation '
    'actually finished at exit 0',
    () {
      test('an inner failure an outer middleware recovers from (returning '
          '0) renders nothing and exits 0', () async {
        final result = await _runWith(
          _cliInnerFailureRecoveredByOuter(),
          ['widget', '--json'],
        );

        expect(result.exitCode, equals(ExitCode.ok));
        expect(result.stderr, isEmpty);
      });

      test('a retry that succeeds on its second attempt renders nothing '
          'and exits 0', () async {
        final result = await _runWith(
          _cliRetryThatSucceeds(_FlakyState()),
          ['widget', '--json'],
        );

        expect(result.exitCode, equals(ExitCode.ok));
        expect(result.stderr, isEmpty);
      });
    },
  );

  group(
    'finding 3: the recorded error is invocation-local, not shared '
    'instance state',
    () {
      test(
        'a recursive cli.run() call that fails does not leak into the '
        'outer call that went on to finish, legitimately, at exit 0',
        () async {
          final capture = _RecursiveCapture();
          final outerErr = MemorySink();
          final outerCode = await _cliForRecursiveRun(capture).run(
            ['outer', '--json'],
            stdout: MemorySink(),
            stderr: outerErr,
          );

          // The nested call genuinely failed, escalated by the same
          // middleware the outer call also goes through.
          expect(capture.innerExitCode, equals(ExitCode.conflict));
          expect(capture.innerStderr, contains('escalated-inner-fail'));

          // The outer call did no throwing of its own: it must finish at
          // exit 0 and render nothing, regardless of what the nested call
          // already recorded and rendered for itself.
          expect(outerCode, equals(ExitCode.ok));
          expect(outerErr.output, isEmpty);
        },
      );

      test(
        'a nested cli.run() call that succeeds does not leak into, or get '
        "overwritten by, the parent's own error once the parent goes on to "
        'fail with its own error afterwards',
        () async {
          final capture = _RecursiveCapture();
          final outerErr = MemorySink();
          final outerCode = await _cliForRecursiveRunThatSucceedsThenParentFails(
            capture,
          ).run(
            ['outer-fails', '--json'],
            stdout: MemorySink(),
            stderr: outerErr,
          );

          // The nested call genuinely succeeded, and rendered nothing of
          // its own.
          expect(capture.innerExitCode, equals(ExitCode.ok));
          expect(capture.innerStderr, isEmpty);

          // The outer call's own error, recorded strictly after the nested
          // call already returned, is what renders: exactly once, and it
          // is the outer query's own error, not anything left behind by
          // the nested call (there was nothing to leave behind) and not
          // duplicated.
          expect(outerCode, equals(ExitCode.dataError));
          final envelope = jsonDecode(outerErr.output) as Map<String, dynamic>;
          final error = envelope['error'] as Map<String, dynamic>;
          expect(
            error['id'],
            equals('outer-failed-after-successful-nested-run'),
          );
          expect(
            'error'.allMatches(outerErr.output).length,
            equals(1),
            reason: 'the envelope must contain exactly one error object',
          );
        },
      );

      test(
        'a middleware that records the parent error before a nested '
        "cli.run() call that succeeds, then returns the original nonzero "
        'code without re-recording, still renders the parent error '
        '(round-8 review finding 4)',
        () async {
          final capture = _RecursiveCapture();
          final outerErr = MemorySink();
          final outerCode =
              await _cliForRecursiveRunPreservingParentErrorRecordedFirst(
            capture,
          ).run(
            ['outer-preserves', '--json'],
            stdout: MemorySink(),
            stderr: outerErr,
          );

          // The nested call genuinely succeeded, and rendered nothing of
          // its own.
          expect(capture.innerExitCode, equals(ExitCode.ok));
          expect(capture.innerStderr, isEmpty);

          // The outer's own error, recorded strictly *before* the nested
          // call even started, is what renders: exactly once, even though
          // the nested call ran to completion, and the outer's own leaf
          // handler ran too, in between it being recorded and the
          // middleware returning its exit code directly.
          expect(outerCode, equals(ExitCode.dataError));
          final envelope = jsonDecode(outerErr.output) as Map<String, dynamic>;
          final error = envelope['error'] as Map<String, dynamic>;
          expect(
            error['id'],
            equals('outer-error-recorded-before-nested-run'),
          );
          expect(
            '"id"'.allMatches(outerErr.output).length,
            equals(1),
            reason: 'the envelope must contain exactly one error object',
          );
        },
      );

      test(
        'two concurrent run() calls on the same instance each render only '
        "their own error, not the other's, proven with an explicit barrier "
        'rather than incidental scheduling: fail-b runs to completion '
        "entirely while fail-a is still suspended, mid-dispatch, on its "
        'own error already having been recorded',
        () async {
          final barrierA = Completer<void>();
          // Round-8 review finding 4: an explicit acknowledgement that
          // fail-a's own dispatch has actually reached barrierA, awaited
          // below before fail-b's run() call even starts, so the ordering
          // this test relies on is established by a real signal, not by
          // fail-a's run() call merely having been started (and not yet
          // awaited) before fail-b's own call begins.
          final reachedBarrierA = Completer<void>();
          final cli = _cliForConcurrentRunsWithBarrier(
            barrierA,
            reachedBarrierA: reachedBarrierA,
          );
          final errA = MemorySink();
          final errB = MemorySink();

          final runA = cli.run(
            ['fail-a', '--json'],
            stdout: MemorySink(),
            stderr: errA,
          );
          await reachedBarrierA.future;

          // fail-b's whole run() call, start to finish, happens while
          // fail-a is parked on barrierA, after fail-a's own error has
          // already been recorded by the escalating middleware but before
          // ModularCli.run() has read it back to render it.
          final codeB = await cli.run(
            ['fail-b', '--json'],
            stdout: MemorySink(),
            stderr: errB,
          );
          expect(codeB, equals(ExitCode.conflict));
          final envelopeB = jsonDecode(errB.output) as Map<String, dynamic>;
          expect(
            (envelopeB['error'] as Map<String, dynamic>)['id'],
            equals('escalated-fail-b'),
          );

          // Only now does fail-a's own dispatch resume and finish.
          barrierA.complete();
          final codeA = await runA;
          expect(codeA, equals(ExitCode.conflict));
          final envelopeA = jsonDecode(errA.output) as Map<String, dynamic>;
          expect(
            (envelopeA['error'] as Map<String, dynamic>)['id'],
            equals('escalated-fail-a'),
          );
        },
      );
    },
  );

  group(
    'finding 4: a literal-prefix alias key must not overwrite a different '
    "shortcut's exact key",
    () {
      test('the bare shortcut "s" validates against its own contract, not '
          'the one "s <id>" declares', () async {
        final result = await _runWith(
          _cliWithBareAndPositionalShortcutsSharingAWord(),
          ['s', '--json', '--a', 'bad', '--help'],
        );

        expect(result.exitCode, equals(ExitCode.validationFailed));
        final envelope = jsonDecode(result.stderr) as Map<String, dynamic>;
        final error = envelope['error'] as Map<String, dynamic>;
        expect(error['id'], equals('validation-failed'));
        expect(error['message'], contains('--a'));
      });

      test('"s <id>" still validates against its own contract afterwards',
          () async {
        final result = await _runWith(
          _cliWithBareAndPositionalShortcutsSharingAWord(),
          // Options go before the trailing positional operand, per
          // cli_router's own grammar ("options go before the program"): the
          // `<id>` value goes last, not right after the literal "s".
          ['s', '--json', '--a', 'ok', '--help', '7'],
        );

        // `--a` is declared as a string on this shortcut, so "ok" is a
        // perfectly valid value: nothing to report, --help wins.
        expect(result.exitCode, equals(ExitCode.ok));
      });
    },
  );

  group(
    'finding 5: a shortcut with no literal words registers the prefix key '
    "cli_router's own rejection actually reports",
    () {
      test('a root shortcut with only a positional ("<id>") is still '
          'consulted when nothing was consumed', () async {
        final result = await _runWith(
          _cliWithRootPositionalOnlyShortcut(),
          ['--json', '--a', 'bad', '--help'],
        );

        expect(result.exitCode, equals(ExitCode.validationFailed));
        final envelope = jsonDecode(result.stderr) as Map<String, dynamic>;
        final error = envelope['error'] as Map<String, dynamic>;
        expect(error['id'], equals('validation-failed'));
        expect(error['message'], contains('--a'));
      });

      test('the same shape mounted under a module ("m <id>") is keyed by '
          'the module name alone, not "m " with a trailing space', () async {
        final result = await _runWith(
          _cliWithModuleMountedPositionalOnlyShortcut(),
          ['m', '--json', '--a', 'bad', '--help'],
        );

        expect(result.exitCode, equals(ExitCode.validationFailed));
        final envelope = jsonDecode(result.stderr) as Map<String, dynamic>;
        final error = envelope['error'] as Map<String, dynamic>;
        expect(error['id'], equals('validation-failed'));
        expect(error['message'], contains('--a'));
      });
    },
  );

  group(
    'finding 6: a resolved mounted shortcut shows its full mounted route '
    'in its own --help',
    () {
      test('text mode shows "Usage: m s", not "Usage: s"', () async {
        final result = await _runWith(
          _cliWithModuleMountedLiteralShortcut(),
          ['m', 's', '--help'],
        );

        expect(result.exitCode, equals(ExitCode.ok));
        expect(result.stdout, contains('Usage: m s'));
        expect(result.stdout, isNot(contains('Usage: s\n')));
      });

      test('JSON mode reports "route": "m s"', () async {
        final result = await _runWith(
          _cliWithModuleMountedLiteralShortcut(),
          ['m', 's', '--json', '--help'],
        );

        expect(result.exitCode, equals(ExitCode.ok));
        final json = jsonDecode(result.stdout) as Map<String, dynamic>;
        expect(json['route'], equals('m s'));
      });
    },
  );

  group(
    'the ambiguous two-candidate case: --help must not win silently, and '
    'no contract may be guessed',
    () {
      test('"s --help" with two shortcuts sharing the same required '
          'parameter at the same prefix reports the router\'s own '
          'rejection instead of granting help', () async {
        final result = await _runWith(
          _cliWithAmbiguousSharedPrefixShortcuts(),
          ['s', '--json', '--help'],
        );

        expect(result.exitCode, equals(ExitCode.invalidUsage));
        final envelope = jsonDecode(result.stderr) as Map<String, dynamic>;
        final error = envelope['error'] as Map<String, dynamic>;
        expect(error['id'], equals('missing-argument'));
        // Not attributed to either shortcut's own contract.
        expect(envelope['error'], isNot(contains('contract')));
      });

      test('the same ambiguity in text mode writes an error, not a usage '
          'line', () async {
        final result = await _runWith(
          _cliWithAmbiguousSharedPrefixShortcuts(),
          ['s', '--help'],
        );

        expect(result.exitCode, equals(ExitCode.invalidUsage));
        expect(result.stderr, contains('Error:'));
        expect(result.stderr, isNot(contains('Usage:')));
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
