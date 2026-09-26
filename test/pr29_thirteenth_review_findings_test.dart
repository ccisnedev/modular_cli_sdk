// Codex round 13 of PR #29 (feat/0.6.0) found two more issues, both in
// modular_cli.dart's help/empty-invocation logic, both stemming from the
// same root cause: whether `help` is a developer's own or the SDK's own
// built-in default was re-derived straight off mutable state on every
// [ModularCli.run] call, instead of being decided once.
//
// Finding 1 (`_registerHelpCommand`, as it was before this round): a
// shortcut named `help` (`shortcut('help', target: 'manual', ...)`) is
// mounted straight onto the router (see `ModuleBuilder.shortcut`), occupying
// the exact trie position the built-in `help *` registration would also
// claim, but, by design, a shortcut is never given a `CommandCatalog` entry.
// The old check (`_catalog.forName('help') != null`) could not see it, so it
// registered the built-in default over it regardless, and the very first
// `run` call threw once the router refused the resulting conflicting
// registration.
//
// Finding 2 (`run`, as it was before this round): `hasCustomHelp` was
// recomputed on every `run` call by reading straight off the catalog, which
// the built-in registration itself mutates the first time it runs. From the
// second `run` call on, the check found its own earlier registration and
// mistook it for a developer's own route, taking a different dispatch path
// (through the router, and whatever middleware sits in front of it) than the
// very first call did (straight to the built-in catalog printer, no
// middleware at all) for the exact same bare invocation on the exact same
// instance, silently flipping success into failure whenever a middleware in
// front of the router happened to fail.
//
// The fix resolves help's provenance exactly once, the first time it is
// needed, as an enum (developer route, developer shortcut, or built-in),
// checking both the catalog and the shortcut maps, caching the answer so
// every later `run` call on the same instance sees the very same value no
// matter what the built-in registration itself goes on to add to the
// catalog.

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

/// No root route, a `manual` route, and a shortcut named `help` targeting
/// it: the SDK's own built-in `help *` must never be registered on top of
/// this, on the very first `run` call or any later one.
ModularCli _cliWithAShortcutNamedHelp() {
  final cli = ModularCli(suggestionDistance: 2);
  cli.query<_WidgetInput, _WidgetOutput>(
    'manual',
    (req) => _OkQuery(marker: 'manual-ran'),
    globals: true,
    contract: CliContract.none,
  );
  cli.shortcut(
    'help',
    target: 'manual',
    globals: true,
    contract: CliContract.none,
  );
  return cli;
}

// ── Finding 2 fixtures ───────────────────────────────────────────────────────

/// No root route or shortcut, no custom help, and a middleware that always
/// fails once actually dispatched through the router: repeated bare `run([])`
/// calls must all take the same path (the built-in catalog printer, which
/// never reaches this middleware at all), never flip from succeeding to
/// failing (or the reverse) partway through.
ModularCli _cliWithNoHelpAndAnAlwaysFailingMiddleware() {
  final cli = ModularCli(suggestionDistance: 2);
  cli.query<_WidgetInput, _WidgetOutput>(
    'other',
    (req) => _OkQuery(),
    globals: true,
    contract: CliContract.none,
  );
  cli.use(
    (next) => (req) async {
      throw CommandException(
        id: 'middleware-always-fails',
        message: 'this middleware always fails once actually dispatched',
        exitCode: ExitCode.apiError,
      );
    },
  );
  return cli;
}

/// A developer-registered custom `help` route (an ordinary route, not a
/// shortcut): a bare invocation must still dispatch to it, exactly as round
/// 12 already established, on the first `run` call and every one after it.
ModularCli _cliWithADeveloperRegisteredHelpRoute() {
  final cli = ModularCli(suggestionDistance: 2);
  cli.query<_WidgetInput, _WidgetOutput>(
    'other',
    (req) => _OkQuery(),
    globals: true,
    contract: CliContract.none,
  );
  cli.query<_WidgetInput, _WidgetOutput>(
    'help',
    (req) => _OkQuery(marker: 'custom-help-ran'),
    globals: true,
    contract: CliContract.none,
  );
  return cli;
}

void main() {
  group('finding 1: a shortcut named help is recognized as a developer\'s '
      'own help before the built-in default is ever registered over it', () {
    test('an explicit ["help"] invocation dispatches to the shortcut\'s own '
        'target, never throwing on a conflicting built-in registration', () async {
      final result = await _runWith(_cliWithAShortcutNamedHelp(), ['help']);

      expect(result.exitCode, equals(ExitCode.ok));
      expect(result.stdout, contains('manual-ran'));
    });

    test('a bare invocation ([]) dispatches to the very same shortcut '
        "target, since no root route or shortcut claims it and help itself "
        'does', () async {
      final result = await _runWith(_cliWithAShortcutNamedHelp(), []);

      expect(result.exitCode, equals(ExitCode.ok));
      expect(result.stdout, contains('manual-ran'));
    });

    test('the same instance answers both an explicit and a bare invocation '
        'identically across repeated calls, never throwing on the second '
        'call either', () async {
      final cli = _cliWithAShortcutNamedHelp();

      final first = await _runWith(cli, ['help']);
      final second = await _runWith(cli, []);
      final third = await _runWith(cli, ['help']);

      expect(first.exitCode, equals(ExitCode.ok));
      expect(second.exitCode, equals(ExitCode.ok));
      expect(third.exitCode, equals(ExitCode.ok));
      expect(first.stdout, contains('manual-ran'));
      expect(second.stdout, contains('manual-ran'));
      expect(third.stdout, contains('manual-ran'));
    });
  });

  group('finding 2: help provenance is resolved once, not re-derived from '
      "the catalog on every run() call, so repeated bare invocations on the "
      'same instance never flip between the built-in-catalog path and the '
      'through-the-router path', () {
    test('three repeated bare run([]) calls on the same instance, with a '
        'middleware that always fails once actually dispatched, all '
        'succeed identically: none of them ever reaches that middleware', () async {
      final cli = _cliWithNoHelpAndAnAlwaysFailingMiddleware();

      final first = await _runWith(cli, []);
      final second = await _runWith(cli, []);
      final third = await _runWith(cli, []);

      expect(first.exitCode, equals(ExitCode.ok));
      expect(second.exitCode, equals(ExitCode.ok));
      expect(third.exitCode, equals(ExitCode.ok));
      expect(first.stdout, contains('other'));
      expect(second.stdout, contains('other'));
      expect(third.stdout, contains('other'));
    });

    test('a developer-registered help route is still dispatched on a bare '
        'invocation, on the first call and every one after it', () async {
      final cli = _cliWithADeveloperRegisteredHelpRoute();

      final first = await _runWith(cli, []);
      final second = await _runWith(cli, []);

      expect(first.exitCode, equals(ExitCode.ok));
      expect(second.exitCode, equals(ExitCode.ok));
      expect(first.stdout, contains('custom-help-ran'));
      expect(second.stdout, contains('custom-help-ran'));
    });
  });
}
