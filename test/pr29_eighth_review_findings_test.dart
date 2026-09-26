// Codex round 8 of PR #29 (feat/0.6.0) found four more issues on top of
// what round 7 fixed.
//
// Finding 1 (modular_cli.dart, run()): a handler throws a CommandException
// with one exit code, and a middleware legitimately remaps the nonzero
// result it gets back into a different exit code of its own. run() used to
// throw StateError the moment the recorded error's own exitCode differed
// from the exit code actually being returned, treating a deliberate remap
// as an invariant violation. The process exit code returned through the
// pipeline is authoritative: the rendered envelope keeps the recorded id,
// message and any extras, but its own exitCode field is stamped with the
// final process exit code, whatever the recorded error's own exitCode was.
//
// Finding 2 (module_builder.dart and ModularCli.use()): a middleware that
// records its own error (JsonCliOutput.writeError, never a throw) before
// calling next(req), then awaits it and returns a nonzero result, lost its
// own recorded error: the reset at handler/middleware entry erased the
// enclosing middleware's own error along with whatever a downstream
// attempt left behind. Outcomes are now a stack of frames per dispatch
// level: entering next() pushes a fresh frame, and on return, the inner
// frame's own error, if it recorded one, supersedes the outer one; if it
// recorded nothing, the outer's own error survives untouched.
//
// Finding 3 (modular_cli.dart, _applicableContractFor()): resolving a
// rejection that never named a specific route by comparing candidates'
// total positional counts picked a "deeper" shortcut even when the router
// itself never actually got far enough to prefer one candidate over the
// other. Resolution must come only from actual routing progress: when more
// than one candidate remains viable at the exact positional the router
// rejected on, the router's own rejection is kept unchanged, not silently
// resolved to a guess.
//
// Finding 4 (test/pr29_sixth_review_findings_test.dart): covered directly
// in that file, not here (its own recursion and concurrency tests, not new
// production behavior).

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

// ── Finding 1 fixtures ───────────────────────────────────────────────────────

/// Runs `next`, and, seeing exactly [ExitCode.notFound] back, remaps it to
/// [ExitCode.genericError] instead: a deliberate, legitimate remap of the
/// process's own exit code, not a bug. The recorded CommandException itself
/// is left exactly as the handler recorded it; only the exit code this call
/// hands back up differs from it.
CliMiddleware _remapsNotFoundToGenericErrorMiddleware() => (next) {
  return (req) async {
    final result = await next(req);
    if (result == ExitCode.notFound) {
      return ExitCode.genericError;
    }
    return result;
  };
};

ModularCli _cliRemapsNotFoundToGenericError() {
  final cli = ModularCli(suggestionDistance: 2);
  cli.query<_WidgetInput, _WidgetOutput>(
    'widget',
    (req) => _ThrowingQuery(
      CommandException(
        id: 'widget-not-found',
        message: 'the widget was not found',
        exitCode: ExitCode.notFound,
      ),
    ),
    globals: true,
    contract: CliContract.none,
  );
  cli.use(_remapsNotFoundToGenericErrorMiddleware());
  return cli;
}

// ── Finding 2 fixtures ───────────────────────────────────────────────────────

/// Records [ownError] directly (never a throw) before calling `next(req)`
/// at all, then returns [ownError.exitCode] itself, ignoring whatever
/// `next` returned: scenario (a), an inner attempt that records nothing of
/// its own.
CliMiddleware _recordsOwnErrorBeforeNextThenReturnsItsOwn(
  CommandException ownError,
) => (next) {
  return (req) async {
    JsonCliOutput(stdout: req.stdout, stderr: req.stderr).writeError(ownError);
    await next(req);
    return ownError.exitCode;
  };
};

/// Records [ownError] directly before calling `next(req)`, then returns
/// whatever `next` itself returned: scenario (b), where the inner attempt
/// may go on to record, and return, an error of its own that must
/// supersede this middleware's own baseline.
CliMiddleware _recordsOwnErrorBeforeNextThenReturnsNextsResult(
  CommandException ownError,
) => (next) {
  return (req) async {
    JsonCliOutput(stdout: req.stdout, stderr: req.stderr).writeError(ownError);
    return await next(req);
  };
};

ModularCli _cliOuterErrorSurvivesASilentInner() {
  final cli = ModularCli(suggestionDistance: 2);
  cli.query<_WidgetInput, _WidgetOutput>(
    'widget',
    (req) => _OkQuery(),
    globals: true,
    contract: CliContract.none,
  );
  cli.use(
    _recordsOwnErrorBeforeNextThenReturnsItsOwn(
      CommandException(
        id: 'outer-recorded-before-next',
        message: "the outer middleware's own error, recorded before next()",
        exitCode: ExitCode.conflict,
      ),
    ),
  );
  return cli;
}

ModularCli _cliInnerErrorSupersedesOuterBaseline() {
  final cli = ModularCli(suggestionDistance: 2);
  cli.query<_WidgetInput, _WidgetOutput>(
    'widget',
    (req) => _ThrowingQuery(
      CommandException(
        id: 'inner-recorded-its-own',
        message: 'the inner handler recorded its own error',
        exitCode: ExitCode.dataError,
      ),
    ),
    globals: true,
    contract: CliContract.none,
  );
  cli.use(
    _recordsOwnErrorBeforeNextThenReturnsNextsResult(
      CommandException(
        id: 'outer-recorded-before-next',
        message: "the outer middleware's own error, recorded before next()",
        exitCode: ExitCode.conflict,
      ),
    ),
  );
  return cli;
}

class _RetryState2 {
  int calls = 0;
}

/// Throws [firstError] on the first call only; every call after that
/// succeeds silently.
class _FailsOnFirstCallOnlyQuery implements Query<_WidgetInput, _WidgetOutput> {
  _FailsOnFirstCallOnlyQuery(this.state, this.firstError);

  final _RetryState2 state;
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

/// Records [ownError] before either attempt runs, retries once if the
/// first attempt is nonzero, and then returns [ownError.exitCode]
/// regardless of how the retry itself turned out: scenario (c). Even
/// though the first, superseded attempt recorded, and had merged in, an
/// error of its own, and the second, final attempt recorded nothing, what
/// must render is this middleware's own baseline, not the first attempt's
/// stale error.
CliMiddleware _recordsOwnErrorThenRetriesOnceReturningItsOwn(
  CommandException ownError,
) => (next) {
  return (req) async {
    JsonCliOutput(stdout: req.stdout, stderr: req.stderr).writeError(ownError);
    var result = await next(req);
    if (result != 0) {
      result = await next(req);
    }
    return ownError.exitCode;
  };
};

ModularCli _cliRetryThatSucceedsStillRendersOuterBaseline() {
  final cli = ModularCli(suggestionDistance: 2);
  final state = _RetryState2();
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
    _recordsOwnErrorThenRetriesOnceReturningItsOwn(
      CommandException(
        id: 'outer-baseline-error',
        message: "the outer middleware's own baseline error",
        exitCode: ExitCode.conflict,
      ),
    ),
  );
  return cli;
}

// ── Finding 3 fixtures ───────────────────────────────────────────────────────

/// An ordinary route `s <id> *`, one required positional and a trailing
/// wildcard, whose own option `a` is an integer, sharing the word `s` and
/// the positional name `id` with a deeper shortcut below.
///
/// `deep <id> <sub> <tail>` exists purely so the shortcut has a target to
/// derive its own positionals from; it is never invoked directly by any
/// test here.
ModularCli _cliWithWildcardRouteAndDeeperOptionalTailShortcut() {
  final cli = ModularCli(suggestionDistance: 2);
  cli.query<_WidgetInput, _WidgetOutput>(
    's <id> *',
    (req) => _OkQuery(),
    globals: true,
    contract: CliContract(
      positionals: [CliPositional.string('id', required: true)],
      options: [
        CliParam.integer(
          'a',
          abbr: null,
          required: false,
          repeatable: false,
          defaultValue: null,
          description: 'An integer the wildcard route declares itself',
        ),
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
    's <id> <sub> [<tail>]',
    target: 'deep',
    globals: true,
    contract: CliContract(
      options: [
        CliParam.string(
          'a',
          abbr: null,
          required: false,
          repeatable: false,
          defaultValue: null,
          description: 'A string the shortcut declares itself',
        ),
      ],
    ),
  );
  return cli;
}

void main() {
  group(
    'finding 1: the process exit code returned through the pipeline is '
    "authoritative over the recorded error's own exitCode",
    () {
      test(
        'a middleware that remaps a notFound result to genericError renders '
        "the handler's own recorded error, stamped with the process's own "
        "final exit code, never a StateError over the mismatch",
        () async {
          final result = await _runWith(
            _cliRemapsNotFoundToGenericError(),
            ['widget', '--json'],
          );

          expect(result.exitCode, equals(ExitCode.genericError));
          final envelope = jsonDecode(result.stderr) as Map<String, dynamic>;
          final error = envelope['error'] as Map<String, dynamic>;
          expect(error['id'], equals('widget-not-found'));
          expect(error['message'], equals('the widget was not found'));
          expect(error['exitCode'], equals(ExitCode.genericError));
          expect(
            'error'.allMatches(result.stderr).length,
            equals(1),
            reason: 'the envelope must contain exactly one error object',
          );
        },
      );
    },
  );

  group(
    'finding 2: outcomes are a stack of frames per dispatch level, not a '
    'single record every next() call resets',
    () {
      test(
        '(a) a middleware that records its own error before next(), whose '
        'inner attempt records nothing, renders its own error',
        () async {
          final result = await _runWith(
            _cliOuterErrorSurvivesASilentInner(),
            ['widget', '--json'],
          );

          expect(result.exitCode, equals(ExitCode.conflict));
          final envelope = jsonDecode(result.stderr) as Map<String, dynamic>;
          final error = envelope['error'] as Map<String, dynamic>;
          expect(error['id'], equals('outer-recorded-before-next'));
        },
      );

      test(
        '(b) a middleware that records its own error before next(), whose '
        "inner attempt records its own, renders the inner attempt's error, "
        "not the middleware's own baseline",
        () async {
          final result = await _runWith(
            _cliInnerErrorSupersedesOuterBaseline(),
            ['widget', '--json'],
          );

          expect(result.exitCode, equals(ExitCode.dataError));
          final envelope = jsonDecode(result.stderr) as Map<String, dynamic>;
          final error = envelope['error'] as Map<String, dynamic>;
          expect(error['id'], equals('inner-recorded-its-own'));
          expect(result.stderr, isNot(contains('outer-recorded-before-next')));
        },
      );

      test(
        '(c) a retry whose second attempt succeeds still renders the '
        "enclosing middleware's own baseline error, not the first, "
        'superseded attempt',
        () async {
          final result = await _runWith(
            _cliRetryThatSucceedsStillRendersOuterBaseline(),
            ['widget', '--json'],
          );

          expect(result.exitCode, equals(ExitCode.conflict));
          final envelope = jsonDecode(result.stderr) as Map<String, dynamic>;
          final error = envelope['error'] as Map<String, dynamic>;
          expect(error['id'], equals('outer-baseline-error'));
          expect(result.stderr, isNot(contains('first-attempt-superseded')));
        },
      );
    },
  );

  group(
    'finding 3: an unresolved rejection is answered only from actual '
    'routing progress, never a positional-count guess',
    () {
      test(
        'a wildcard route and a deeper shortcut sharing the same first '
        'positional name both remain viable at a missing-argument '
        "rejection for it, so the router's own rejection is kept, never a "
        'success help render under the wrong contract',
        () async {
          final result = await _runWith(
            _cliWithWildcardRouteAndDeeperOptionalTailShortcut(),
            ['s', '--json', '--a', 'bad', '--help'],
          );

          expect(result.exitCode, isNot(equals(ExitCode.ok)));
          expect(result.stdout, isEmpty);
        },
      );
    },
  );
}

// ── Test harness ─────────────────────────────────────────────────────────────

Future<({int exitCode, String stdout, String stderr})> _runWith(
  ModularCli cli,
  List<String> args,
) async {
  final out = MemorySink();
  final err = MemorySink();
  final code = await cli.run(args, stdout: out, stderr: err);
  return (exitCode: code, stdout: out.output, stderr: err.output);
}
