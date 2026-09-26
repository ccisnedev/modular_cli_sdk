// Codex round 12 of PR #29 (feat/0.6.0) found two more issues, both in
// modular_cli.dart.
//
// Finding 1 (`_applicableContractFor`): [CliRejectionKind.misplacedOption]
// can leave [CliRejection.route] null yet still populate
// [CliRejection.candidates] with the exact, genuinely ambiguous routes still
// reachable from here (see that field's own doc comment on `cli_router`'s
// own [CliRejection]). Before this round's fix, the method never consulted
// [CliRejection.candidates] at all: it fell straight through to the
// name-based fallback, matching [CliRejection.consumed] alone, the shallower
// literal prefix every candidate shares. Two sibling routes declaring the
// same option (`s a` and `s b`, both under `s`) then resolved to the
// *ancestor* route `s`'s own contract instead of reporting the genuine
// ambiguity between the actual descendants, attaching a wrong, unrelated
// contract (one that may not even declare the option in question) to the
// error.
//
// The fix consults [CliRejection.candidates] first, whenever it is
// non-empty, resolving purely from that list (zero registered contracts:
// nothing to answer with; exactly one: the unambiguous answer; more than
// one: genuinely ambiguous), before the name-based fallback ever runs. This
// does not exclude `misplacedOption` wholesale: a `misplacedOption` whose
// `candidates` stays empty still falls through to the very same name-based
// resolution every other kind uses.
//
// Finding 2 (`run`): a bare invocation used to mean "print the built-in
// catalog" whenever no root *route* existed, never considering two other
// things that already answer a bare invocation on their own: a root
// *shortcut* (invisible to a plain [CommandCatalog.forRoute] lookup, by
// design), and a developer's own `help` route, registered before
// `_registerHelpCommand` ever runs. The old code never dispatched through
// the router at all when there was no root route, so neither ever got a
// chance to answer: a root shortcut's own target never ran, and a
// developer's own `help` handler was bypassed outright, a regression
// against `origin/main`'s own args-rewriting approach.
//
// The fix restores a real, three-way, declared order: a root route or root
// shortcut, when either is registered, answers the bare invocation exactly
// as any other invocation of it would; otherwise a `help` command
// registered before this call answers it instead (dispatch continues with
// `['help']`); and only when neither exists at all does this fall back to
// printing the built-in catalog directly, exactly as before.

import 'dart:convert';

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

/// `s` (no options), and two descendants `s a` / `s b`, both declaring the
/// same `--verbose` flag: `s --json --verbose` reaches `s`, an option that
/// belongs to `s a`/`s b` alone, genuinely ambiguous between them.
ModularCli _cliWithAmbiguousSiblingsSharingAnOption() {
  final cli = ModularCli(suggestionDistance: 2);
  cli.query<_WidgetInput, _WidgetOutput>(
    's',
    (req) => _OkQuery(),
    globals: true,
    contract: CliContract.none,
  );
  final verboseContract = CliContract(
    options: [CliParam.flag('verbose', abbr: null, repeatable: false)],
  );
  cli.query<_WidgetInput, _WidgetOutput>(
    's a',
    (req) => _OkQuery(),
    globals: true,
    contract: verboseContract,
  );
  cli.query<_WidgetInput, _WidgetOutput>(
    's b',
    (req) => _OkQuery(),
    globals: true,
    contract: verboseContract,
  );
  return cli;
}

// ── Finding 2 fixtures ───────────────────────────────────────────────────────

/// No root route or shortcut, no custom `help`: a bare invocation should
/// still fall back to printing the built-in catalog, exactly as before.
ModularCli _cliWithNoRootAndNoCustomHelp() {
  final cli = ModularCli(suggestionDistance: 2);
  cli.query<_WidgetInput, _WidgetOutput>(
    'other',
    (req) => _OkQuery(),
    globals: true,
    contract: CliContract.none,
  );
  return cli;
}

/// No root route, but a root *shortcut* targeting `status`: a bare
/// invocation should dispatch to `status`, not print the catalog.
ModularCli _cliWithARootShortcut() {
  final cli = ModularCli(suggestionDistance: 2);
  cli.query<_WidgetInput, _WidgetOutput>(
    'status',
    (req) => _OkQuery(marker: 'status-ran'),
    globals: true,
    contract: CliContract.none,
  );
  cli.shortcut(
    '',
    target: 'status',
    globals: true,
    contract: CliContract.none,
  );
  return cli;
}

/// No root route or shortcut, but a developer-registered custom `help`
/// route (not the SDK's own auto-registered default): a bare invocation
/// should dispatch to it, not print the generic catalog.
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
  group('finding 1: a misplacedOption rejection whose CliRejection.candidates '
      'is non-empty resolves from that list alone, never from the shallower '
      "ancestor prefix CliRejection.consumed alone would name", () {
    test('in --json mode, the error envelope carries no contract field at '
        'all: the ancestor route s does not declare --verbose, and the two '
        'descendants that do stay genuinely ambiguous between themselves', () async {
      final result = await _runWith(
        _cliWithAmbiguousSiblingsSharingAnOption(),
        ['s', '--json', '--verbose'],
      );

      expect(result.exitCode, equals(ExitCode.validationFailed));
      final envelope = jsonDecode(result.stderr) as Map<String, dynamic>;
      final error = envelope['error'] as Map<String, dynamic>;
      expect(error['id'], equals('misplaced-option'));
      expect(error.containsKey('contract'), isFalse);
    });

    test('in text mode, the same rejection never renders the ancestor '
        "route's own usage as if it were the answer, listing the two "
        'genuinely ambiguous descendants instead', () async {
      final result = await _runWith(
        _cliWithAmbiguousSiblingsSharingAnOption(),
        ['s', '--verbose'],
      );

      expect(result.exitCode, equals(ExitCode.validationFailed));
      expect(result.stderr, isNot(contains('Usage: s\n')));
      expect(result.stderr, contains('s a'));
      expect(result.stderr, contains('s b'));
    });
  });

  group('finding 2: a bare invocation dispatches, in declared order, to a '
      'root route or root shortcut, else a registered help handler, else '
      'the built-in catalog', () {
    test('a root shortcut, when registered, actually runs its target: a '
        'bare invocation does not print the catalog instead', () async {
      final result = await _runWith(_cliWithARootShortcut(), []);

      expect(result.exitCode, equals(ExitCode.ok));
      expect(result.stdout, contains('status-ran'));
    });

    test('a developer-registered help route, when no root route or '
        'shortcut exists, actually runs: a bare invocation does not print '
        'the generic catalog instead', () async {
      final result = await _runWith(
        _cliWithADeveloperRegisteredHelpRoute(),
        [],
      );

      expect(result.exitCode, equals(ExitCode.ok));
      expect(result.stdout, contains('custom-help-ran'));
    });

    test('with neither a root route/shortcut nor a developer help route, a '
        'bare invocation still falls back to the built-in catalog', () async {
      final result = await _runWith(_cliWithNoRootAndNoCustomHelp(), []);

      expect(result.exitCode, equals(ExitCode.ok));
      expect(result.stdout, contains('other'));
    });
  });
}
