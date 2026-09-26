// Codex round 7 of PR #29 (feat/0.6.0) found two more issues, on top of what
// round 6 fixed.
//
// Finding 1 (modular_cli.dart, run()): a middleware that retries by calling
// `next(req)` more than once could leave a stale error behind. Attempt 1
// throws a CommandException, recorded and converted into a plain exit code
// by ModuleBuilder._mount()'s own boundary; the middleware sees that nonzero
// code and retries; attempt 2 either succeeds outright (an Output whose own
// exitCode happens to be nonzero, but nothing thrown) or throws a different
// CommandException of its own. Either way, what run() renders must
// correspond to the *final* attempt, never a superseded one: a fresh
// dispatch attempt starts with a clean recorded-error slot, discarding
// whatever an earlier, superseded attempt left behind.
//
// Finding 2 (modular_cli.dart, _handleRejection()): an ordinary catalog
// route and a shortcut can share a literal prefix at different positional
// depths (`s`, no positionals, next to a shortcut `s <id> <sub>`, two of
// them). A rejection that never resolved a specific route (CliRejection.route
// is null: incomplete or missingArgument) is looked up by name alone against
// the catalog first, so the shallower, unrelated catalog route's own
// contract silently overrode the deeper shortcut the invocation was actually
// reaching for, letting a badly typed value on the shortcut's own option
// pass validation under the catalog route's more permissive one.

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

/// An [Output] whose exit code is whatever the test wants, not fixed at
/// [ExitCode.ok]: finding 1's "2-then-4" scenario needs a *successful*
/// attempt (nothing thrown) whose own [Output.exitCode] is still nonzero.
class _CodedOutput extends Output {
  _CodedOutput(this.code);

  final int code;

  @override
  Map<String, dynamic> toJson() => {'code': code};

  @override
  int get exitCode => code;
}

class _RetryState {
  int calls = 0;
}

/// Throws [firstThrow] on its first call; every call after that succeeds
/// with a [_CodedOutput] carrying [secondCode], which may itself be
/// nonzero.
class _ThrowThenNonzeroSuccessQuery implements Query<_WidgetInput, _CodedOutput> {
  _ThrowThenNonzeroSuccessQuery(
    this.state, {
    required this.firstThrow,
    required this.secondCode,
  });

  final _RetryState state;
  final CommandException firstThrow;
  final int secondCode;

  @override
  final _WidgetInput input = _WidgetInput();

  @override
  String? validate() => null;

  @override
  Future<_CodedOutput> execute() async {
    state.calls++;
    if (state.calls == 1) throw firstThrow;
    return _CodedOutput(secondCode);
  }
}

/// Throws [first] on its first call and [second] on every call after: both
/// attempts fail, but with different errors.
class _ThrowTwiceDifferentQuery implements Query<_WidgetInput, _WidgetOutput> {
  _ThrowTwiceDifferentQuery(this.state, {required this.first, required this.second});

  final _RetryState state;
  final CommandException first;
  final CommandException second;

  @override
  final _WidgetInput input = _WidgetInput();

  @override
  String? validate() => null;

  @override
  Future<_WidgetOutput> execute() async {
    state.calls++;
    throw state.calls == 1 ? first : second;
  }
}

/// Retries exactly once: calls `next(req)`, and, only if that result is
/// nonzero, calls it a second time and returns that result instead. Neither
/// call is inspected any further, exactly the shape finding 1 describes: the
/// middleware decides to retry from the plain exit code alone, never from a
/// caught exception (ModuleBuilder._mount() never lets one propagate past
/// its own boundary).
CliMiddleware _retryOnceMiddleware() => (next) {
  return (req) async {
    var result = await next(req);
    if (result != 0) {
      result = await next(req);
    }
    return result;
  };
};

// ── Finding 1 fixtures ───────────────────────────────────────────────────────

ModularCli _cliRetrySucceedsWithNonzeroExitCode(_RetryState state) {
  final cli = ModularCli(suggestionDistance: 2);
  cli.query<_WidgetInput, _CodedOutput>(
    'widget',
    (req) => _ThrowThenNonzeroSuccessQuery(
      state,
      firstThrow: CommandException(
        id: 'first-attempt-failed',
        message: 'the first attempt failed',
        exitCode: ExitCode.apiError,
      ),
      secondCode: ExitCode.notFound,
    ),
    globals: true,
    contract: CliContract.none,
  );
  cli.use(_retryOnceMiddleware());
  return cli;
}

ModularCli _cliRetryThrowsDifferentErrorEachAttempt(_RetryState state) {
  final cli = ModularCli(suggestionDistance: 2);
  cli.query<_WidgetInput, _WidgetOutput>(
    'widget',
    (req) => _ThrowTwiceDifferentQuery(
      state,
      first: CommandException(
        id: 'first-attempt-error',
        message: 'the first attempt failed',
        exitCode: ExitCode.apiError,
      ),
      second: CommandException(
        id: 'second-attempt-error',
        message: 'the second attempt failed too, differently',
        exitCode: ExitCode.conflict,
      ),
    ),
    globals: true,
    contract: CliContract.none,
  );
  cli.use(_retryOnceMiddleware());
  return cli;
}

// ── Finding 2 fixtures ───────────────────────────────────────────────────────

/// An ordinary route named exactly `s`, no positionals, whose own option
/// `a` is a string: the shallow, unrelated catalog match that must not win
/// against a deeper shortcut sharing the same literal word.
///
/// `deep <id> <sub>` exists purely so the shortcut below has a target to
/// derive its own positionals from (`ModuleBuilder.shortcut` requires one);
/// it is never invoked directly by any test here.
ModularCli _cliWithOrdinaryRouteAndDeeperShortcutSharingAWord() {
  final cli = ModularCli(suggestionDistance: 2);
  cli.query<_WidgetInput, _WidgetOutput>(
    's',
    (req) => _OkQuery(),
    globals: true,
    contract: CliContract(
      options: [
        CliParam.string(
          'a',
          abbr: null,
          required: false,
          repeatable: false,
          defaultValue: null,
          description: 'A string the ordinary route declares itself',
        ),
      ],
    ),
  );
  cli.query<_WidgetInput, _WidgetOutput>(
    'deep <id> <sub>',
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
    's <id> <sub>',
    target: 'deep',
    globals: true,
    contract: CliContract(
      options: [
        CliParam.integer(
          'a',
          abbr: null,
          required: false,
          repeatable: false,
          defaultValue: null,
          description: 'An integer the shortcut declares itself',
        ),
      ],
    ),
  );
  return cli;
}

void main() {
  group(
    'finding 1: what run() renders must correspond to the final dispatch '
    'attempt, never a superseded one',
    () {
      test(
        'a retry whose second attempt succeeds with a nonzero exit code '
        'renders nothing, and the process exit code is the final '
        "attempt's own, not the first attempt's stale error",
        () async {
          final result = await _runWith(
            _cliRetrySucceedsWithNonzeroExitCode(_RetryState()),
            ['widget', '--json'],
          );

          expect(result.exitCode, equals(ExitCode.notFound));
          expect(result.stderr, isEmpty);
          expect(result.stderr, isNot(contains('first-attempt-failed')));
        },
      );

      test(
        "a retry whose second attempt throws a different error renders "
        "only the final attempt's own error, at the final attempt's own "
        'exit code',
        () async {
          final result = await _runWith(
            _cliRetryThrowsDifferentErrorEachAttempt(_RetryState()),
            ['widget', '--json'],
          );

          expect(result.exitCode, equals(ExitCode.conflict));
          final envelope = jsonDecode(result.stderr) as Map<String, dynamic>;
          final error = envelope['error'] as Map<String, dynamic>;
          expect(error['id'], equals('second-attempt-error'));
          expect(error['exitCode'], equals(ExitCode.conflict));
          expect(result.stderr, isNot(contains('first-attempt-error')));
        },
      );
    },
  );

  group(
    'finding 2: a name-only catalog match must not override a shortcut the '
    'invocation positionally matches further',
    () {
      test(
        'a badly typed value on the deeper shortcut\'s own option fails '
        "validation against the shortcut's contract, not the shallower "
        "ordinary route's",
        () async {
          final result = await _runWith(
            _cliWithOrdinaryRouteAndDeeperShortcutSharingAWord(),
            ['s', '--json', '--a', 'bad', '--help', '7'],
          );

          expect(result.exitCode, equals(ExitCode.validationFailed));
          final envelope = jsonDecode(result.stderr) as Map<String, dynamic>;
          final error = envelope['error'] as Map<String, dynamic>;
          expect(error['id'], equals('validation-failed'));
          expect(error['message'], contains('--a'));
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
