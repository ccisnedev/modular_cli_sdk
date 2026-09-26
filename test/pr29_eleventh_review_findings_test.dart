// Codex round 11 of PR #29 (feat/0.6.0) found two more issues.
//
// Finding 1 (invocation_outcome.dart, `runWithInvocationOutcome`): round-10's
// own fix (`InvocationOutcome.runAttempt`) binds `_currentFrameKey` to a
// fresh frame for every `next()` attempt, but `runWithInvocationOutcome`
// itself never binds `_currentFrameKey` at all: it only introduces a new
// zone value for `_invocationOutcomeKey`. A nested call to it (a handler
// that itself calls `cli.run(...)` again, its own sinks and all) still
// inherits whatever `_currentFrameKey` already resolves to in its *caller's*
// zone, unchanged, via ordinary [Zone] ancestor lookup. When that nested call
// runs from inside an already-active attempt (a `ModularCli.use()`
// middleware's guarded `next()`), the frame it inherits is not some frame of
// its own kind, it is literally the very same `_OutcomeFrame` object the
// outer attempt is watching, belonging to a completely different
// [InvocationOutcome]. The nested invocation's own `recordInvocationError`
// call then writes its error straight into that shared frame, so once the
// nested `run()` returns and the outer attempt settles, the outer attempt
// reads back an error it never recorded, one that belongs entirely to a
// separate, already-finished invocation that already rendered it once, into
// its own, separate sinks.
//
// The fix binds `_currentFrameKey` to the new [InvocationOutcome]'s own base
// frame in the very same [runZoned] call `runWithInvocationOutcome` already
// makes: every invocation zone, nested or not, now establishes its own frame
// binding that shadows whatever a parent's own attempt happens to have
// bound, so a nested `run()` call can never again land in a frame it does
// not own.
//
// Finding 2 (modular_cli.dart, `_applicableContractFor`): round-10's own fix
// to this method (finding 2 of that round) asks [CommandCatalog.allForName]
// for the empty prefix exactly like any other, no longer skipping it whenever
// [CliRejection.consumed] happened to be empty. That fix was correct for the
// ambiguity it was written for (a root positional-only route and a deeper
// shortcut genuinely disagreeing on a missing positional), but it also means
// that a CLI with a bare root route registered (`''`, no positionals either,
// a dashboard or a status screen) now has that route resolve as the sole
// candidate for *any* rejection whose own consumed prefix happens to be
// empty too, including a genuinely unrelated [CliRejectionKind.unknownCommand]
// for a top-level word the catalog never registered at all. Unlike a
// [CliRejectionKind.missingArgument] or [CliRejectionKind.incomplete], an
// unknown command is never "the beginning of a real route this invocation
// was one flag away from honouring": no contract answers it, however many
// routes happen to share that empty prefix.
//
// The fix declares this per [CliRejection.kind], explicitly, before any
// candidate is even collected: [CliRejectionKind.unknownCommand] never
// resolves a contract, full stop, while every other kind keeps consulting
// the candidate list exactly as round-10 left it, root route included.

import 'dart:async';
import 'dart:convert';

import 'package:modular_cli_sdk/modular_cli_sdk.dart';
import 'package:modular_cli_sdk/src/invocation_outcome.dart';
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

/// Always throws [error], never actually returning: stands in for a nested
/// invocation's own route, one that always fails.
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

/// A plain, successful [Output] whose [exitCode] is whatever the fixture
/// chooses, nonzero included: no throw, no recording, exactly the "returns a
/// nonzero output without recording" shape the finding describes.
class _NonzeroOutput extends Output {
  _NonzeroOutput(this.exitCode);

  @override
  final int exitCode;

  @override
  Map<String, dynamic> toJson() => {'ok': false, 'exitCode': exitCode};
}

/// Captured after the nested invocation below runs, so the test can assert on
/// it independently of the parent's own result.
class _NestedRunResult {
  int? exitCode;
  String? stderr;
}

/// Runs a second, wholly separate [ModularCli] invocation (its own sinks,
/// its own [InvocationOutcome]) that always fails, from inside a handler
/// already running inside an active attempt (a [ModularCli.use] middleware's
/// guarded `next()`), then returns its own, plain nonzero [Output.exitCode]
/// without itself throwing or recording anything.
class _RunsFailingNestedInvocationThenReturnsNonzeroQuery
    implements Query<_WidgetInput, _NonzeroOutput> {
  _RunsFailingNestedInvocationThenReturnsNonzeroQuery(
    this.nestedError,
    this.parentExitCode,
    this.nestedResult,
  );

  final CommandException nestedError;
  final int parentExitCode;
  final _NestedRunResult nestedResult;

  @override
  final _WidgetInput input = _WidgetInput();

  @override
  String? validate() => null;

  @override
  Future<_NonzeroOutput> execute() async {
    final nested = ModularCli(suggestionDistance: 2);
    nested.query<_WidgetInput, _WidgetOutput>(
      'boom',
      (req) => _FailingQuery(nestedError),
      globals: true,
      contract: CliContract.none,
    );

    final nestedOut = MemorySink();
    final nestedErr = MemorySink();
    final exitCode = await nested.run(
      ['boom', '--json'],
      stdout: nestedOut,
      stderr: nestedErr,
    );
    nestedResult
      ..exitCode = exitCode
      ..stderr = nestedErr.output;

    return _NonzeroOutput(parentExitCode);
  }
}

ModularCli _cliRunningAFailingNestedInvocationInsideAnActiveAttempt(
  CommandException nestedError,
  int parentExitCode,
  _NestedRunResult nestedResult,
) {
  final cli = ModularCli(suggestionDistance: 2);
  cli.query<_WidgetInput, _NonzeroOutput>(
    'widget',
    (req) => _RunsFailingNestedInvocationThenReturnsNonzeroQuery(
      nestedError,
      parentExitCode,
      nestedResult,
    ),
    globals: true,
    contract: CliContract.none,
  );
  // A passthrough middleware, registered purely to give the dispatch an
  // active attempt (InvocationOutcome.runAttempt) around the handler above,
  // exactly as any ModularCli.use() middleware does.
  cli.use((next) => (req) => next(req));
  return cli;
}

// ── Finding 2 fixtures ───────────────────────────────────────────────────────

/// A bare root route (no literal words, no positionals: a dashboard or
/// status screen) alongside an unrelated sibling command, registered purely
/// so a full-catalog render is distinguishable from the root route's own,
/// solitary usage.
ModularCli _cliWithBareRootRouteAndASiblingCommand() {
  final cli = ModularCli(suggestionDistance: 2);
  cli.query<_WidgetInput, _WidgetOutput>(
    '',
    (req) => _OkQuery(),
    globals: true,
    contract: CliContract.none,
  );
  cli.query<_WidgetInput, _WidgetOutput>(
    'other',
    (req) => _OkQuery(),
    globals: true,
    contract: CliContract.none,
  );
  return cli;
}

void main() {
  group('finding 1: runWithInvocationOutcome binds a nested invocation\'s own '
      'frame alongside its own outcome, so it can never land in an active '
      "outer attempt's frame merely by inheriting whatever the enclosing "
      'zone already bound', () {
    test('a handler that runs a failing nested run() from inside an active '
        'attempt, then returns its own plain nonzero output without '
        "recording anything itself, does not have the nested run's error "
        "rendered again by the parent: the parent's own outcome (nothing, "
        "here) is what renders, exactly once, for the parent's own "
        'invocation', () async {
      final nestedError = CommandException(
        id: 'nested-invocation-failure',
        message: 'the nested invocation always fails',
        exitCode: ExitCode.apiError,
      );
      final nestedResult = _NestedRunResult();

      final result = await _runWith(
        _cliRunningAFailingNestedInvocationInsideAnActiveAttempt(
          nestedError,
          ExitCode.dataError,
          nestedResult,
        ),
        ['widget', '--json'],
      );

      // The nested invocation genuinely failed and rendered its own error,
      // once, into its own, separate sinks.
      expect(nestedResult.exitCode, equals(ExitCode.apiError));
      expect(nestedResult.stderr, contains('nested-invocation-failure'));

      // The parent's own handler returned its own plain nonzero exit code,
      // unrelated to the nested invocation's.
      expect(result.exitCode, equals(ExitCode.dataError));

      // The parent's own outcome recorded nothing: nothing renders for it,
      // and in particular the nested invocation's own, already-rendered
      // error must not show up a second time on the parent's own stderr.
      expect(result.stderr, isEmpty);
      expect(result.stderr, isNot(contains('nested-invocation-failure')));
    });

    test('the same nested-frame isolation holds at the InvocationOutcome '
        'level directly: a nested runWithInvocationOutcome call, made from '
        "inside an active outer attempt, records into its own base frame, "
        "never into the outer attempt's frame it happens to be running "
        'inside of', () async {
      RecordedOutcome? outerAttempt;

      final outerResult = await runWithInvocationOutcome(() async {
        final outerOutcome = currentInvocationOutcome();
        return await outerOutcome.runAttempt<int>(() async {
          final nestedError = CommandException(
            id: 'nested-frame-leak',
            message: 'recorded by a nested invocation',
            exitCode: ExitCode.genericError,
          );
          final nestedExit = await runWithInvocationOutcome(() async {
            recordInvocationError(nestedError, jsonMode: false);
            return nestedError.exitCode;
          });
          expect(nestedExit, equals(ExitCode.genericError));

          // The outer attempt's own body records nothing of its own.
          return 7;
        }, onSettled: (recorded) => outerAttempt = recorded);
      });

      expect(outerResult, equals(7));
      expect(outerAttempt, isNull);
    });
  });

  group('finding 2: an unknownCommand rejection never resolves a contract, '
      'whatever CommandCatalog.allForName finds registered under its '
      "(possibly empty) consumed prefix, so a bare root route's own contract "
      "is never attached to an error about a wholly unrelated, unrecognized "
      'top-level word', () {
    test('in --json mode, the error envelope carries no contract field at '
        'all for an unknown top-level word', () async {
      final result = await _runWith(
        _cliWithBareRootRouteAndASiblingCommand(),
        ['--json', 'bogus'],
      );

      expect(result.exitCode, equals(ExitCode.invalidUsage));
      final envelope = jsonDecode(result.stderr) as Map<String, dynamic>;
      final error = envelope['error'] as Map<String, dynamic>;
      expect(error['id'], equals('unknown-command'));
      expect(error.containsKey('contract'), isFalse);
    });

    test('in text mode, the same rejection prints the full command catalog, '
        "never the root route's own usage alone", () async {
      final result = await _runWith(
        _cliWithBareRootRouteAndASiblingCommand(),
        ['bogus'],
      );

      expect(result.exitCode, equals(ExitCode.invalidUsage));
      expect(result.stderr, contains('other'));
    });
  });
}
