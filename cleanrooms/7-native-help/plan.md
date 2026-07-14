---
id: plan
title: "Plan"
date: 2026-07-13
status: active
tags: [plan]
---

# Plan

**Issue:** #7 — Native help: contract catalog, `--help`/`-h`/no-args, and `help.json`
**Baseline:** `cleanrooms/7-native-help/analyze/diagnosis.md` (decisions D1–D7; OQ1–OQ3 closed there, OQ4 answered in "Delivery" below)

**Hypothesis.** If the contract is modelled first (Phase 2), enforced at the single point where the
command lifecycle already lives (Phase 3), and only then *rendered* through every help surface
(Phases 4–7), the diagnosed problem — a framework that cannot describe its own commands, and four
help entry points that all fail as errors — is solved without a second, hand-maintained truth.

**Repos touched (two).** `cli_router` (`C:\Users\44358590\Code\macss\cli_router`, → 0.1.0, D7) and
`modular_cli_sdk` (this repo). Phase 1 is the only `cli_router` work; everything else is SDK.

**Delivery / dependency handling (answers OQ4).** Phase 1 lands and is released as `cli_router`
**0.1.0** (D7: `^0.0.z` permits no upgrade in Dart, which is what pinned the SDK to 0.0.2 — F4).
While 0.1.0 is unpublished, SDK phases develop against a local pin:

```yaml
# modular_cli_sdk/pubspec.yaml — TEMPORARY, must not survive Phase 8
dependency_overrides:
  cli_router:
    path: ../cli_router
```

Merge is blocked until `pubspec.yaml` reads `cli_router: ^0.1.0`, `dependency_overrides` is gone, and
`pubspec.lock` resolves 0.1.0 from pub.dev (Phase 8). Constraint C10.

---

## Phase 1 — `cli_router` 0.1.0: route introspection + `onNotFound` hook

Repo: `C:\Users\44358590\Code\macss\cli_router`. Implements D6 (the router stops deciding *how* a
failure is presented) and the introspection half of H2. Additive: with no hook injected, behaviour is
byte-identical to today.

- **Entry criteria**: none (first phase; no dependency on SDK work).
- **Covers**: enabling change for AC-4 (error path) and AC-6 (positionals in help); no AC by itself.
- **Steps**:
  - [x] RED: add `test/not_found_hook_test.dart` — (a) with no hook, an unmatched arg list still writes `Command not found or invalid usage.` + listing to stderr and returns 64 (current behaviour preserved); (b) with `onNotFound` injected, the router calls it with the unmatched args and returns the hook's exit code, writing **nothing** itself.
  - [x] RED: add `test/list_commands_metadata_test.dart` — `listCommands()` exposes, per route, the literal segments and the **positional names** (`show <id>` ⇒ `positionals: ['id']`), and reports mounts, so a caller can build a per-module view.
  - [x] Add the hook to `CliRouter` (typedef `CliNotFoundHandler = FutureOr<int> Function(CliNotFound)`), invoked at the fallback in `lib/src/cli_router.dart:166-170`; keep the current stderr output as the default when the hook is null.
  - [x] Extend `ListedCommand` (`lib/src/route_entry.dart:22-26`) with the route's structural metadata (`positionals`, and whether it came from a mount) — the data already exists in `_PathPattern`/`_Segment` (`lib/src/path_pattern.dart:50-60`) and is currently discarded.
  - [x] Bump `pubspec.yaml` to `version: 0.1.0` and write the `CHANGELOG.md` entry (added: `onNotFound`, route metadata; no breaking change).
- **Shared type change — `ListedCommand`.** Search strategy: `rg -n "ListedCommand|listCommands|printHelp" C:\Users\44358590\Code\macss\cli_router C:\Users\44358590\Code\macss\modular_cli_sdk` (run in both repos, since the type crosses the package boundary).
  - Construction sites (must be updated): `lib/src/cli_router.dart:68` (`out.add(ListedCommand(...))`) — the only place the type is built; the constructor itself at `lib/src/route_entry.dart:23`.
  - Consumer sites: `lib/src/cli_router.dart:79-95` (`printHelp` iterates `c.command` / `c.description`), `example/example.dart:32` (`root.printHelp(...)`), and — in the SDK — `lib/src/modular_cli.dart:87-89` (`ModularCli.printHelp`). Adding fields with defaults keeps all of them compiling; that is the acceptance bar.
- **Verify**: `cd C:\Users\44358590\Code\macss\cli_router && dart test` — green, including the pre-existing `test/empty_route_test.dart` and `test/empty_mount_test.dart` (proves the 0.0.3 catch-all guard, C3, is untouched).
- **Risk**: touching the fallback is the one place every unmatched invocation flows through; the "no hook ⇒ identical output" test in `test/not_found_hook_test.dart` is the guard.

## Phase 2 — SDK: the contract type (`CliParam`) and its declaration seat

Implements D3. Pure model + registry; no behaviour change yet.

- **Entry criteria**: Phase 1 merged locally; `dependency_overrides` pin in place.
- **Covers**: enabling change for AC-5/AC-6 of US-2 (parameters with description, required, default, aliases, positionals).
- **Steps**:
  - [x] RED: add `test/cli_param_test.dart` — construction of each kind (option / boolean flag / positional), each type (`string`, `int`, `double`, `bool`), `abbr`, `required`, `defaultValue`, `allowed`, `description`; and `toJson()` (the shape `help --json` will emit in Phase 6). **Deviation (EXECUTE):** `repeatable` was dropped from `CliParam` — `cli_router` keys flags by name (`Map<String, String?>`), so a repeated flag overwrites the previous one and the facet could not be honoured; declaring it would have made help describe behaviour the runtime does not have, the very defect this issue fixes. `negatable` was likewise not declared: `--no-x` is already handled by the parser (`flags_parser.dart:44-46`) and needs no declaration.
  - [x] Add `lib/src/cli_param.dart` with `CliParam` + named factories (`CliParam.integer`, `.string`, `.boolean`, `.positional`), CLI-native — **not** a copy of `modular_api`'s `SchemaField`, which has no alias/default/kind (diagnosis F8).
  - [x] Export it from `lib/modular_cli_sdk.dart`.
  - [x] Type the declaration seat: `Input.schemaFields` becomes `List<CliParam>? get schemaFields => null` (`lib/src/input.dart:31`), the seat already reserved for exactly this.
  - [x] Extend registration to carry the DTO's declaration: `ModuleBuilder.command(..., {String? description, List<CliParam> params = const []})` (`lib/src/module_builder.dart:46-50`) and the same optional argument on `ModularCli.command` (`lib/src/modular_cli.dart:59-68`), storing route → contract in a registry owned by `ModularCli`.
- **Shared type change — `schemaFields` and `command(...)`.** Search strategy: `rg -n "schemaFields|\.command<|\.command\(|extends Input|extends Output" lib example test`.
  - `schemaFields` construction/override sites: declared at `lib/src/input.dart:31` and `lib/src/output.dart:33`; **no subclass overrides it today** (the grep returns only the two declarations plus the two tests below), so narrowing `List<dynamic>?` to `List<CliParam>?` on `Input` breaks nothing. `Output.schemaFields` is left untouched in this issue (it describes results, not invocation).
  - `schemaFields` consumer sites: `test/input_test.dart:20-22`, `test/output_test.dart:39-41` (assert `isNull` — still true by default).
  - `command(...)` call sites (all must keep compiling with the new optional arg): `example/example.dart:33`, `example/modules/greetings/greetings_builder.dart:6`, `example/modules/math/math_builder.dart:7,13`, `test/integration_test.dart:144,149,157,307,326,332,339`, and the internal delegation at `lib/src/modular_cli.dart:66`.
- **Verify**: `dart test test/cli_param_test.dart test/input_test.dart test/output_test.dart` — green.
- **Risk**: none behavioural (additive, optional). C5 (backward compatibility) is proven by the untouched `test/integration_test.dart` in the Final verification.

## Phase 3 — SDK: enforcement (declaring is parsing)

Implements D4 and the SDK half of D5. This is the phase that makes the catalog *true*.

- **Entry criteria**: Phase 2 green.
- **Covers**: the §4 "cannot drift" rule; prerequisite for every AC of US-2 being honest.
- **Steps**:
  - [x] RED: add `test/enforcement_test.dart` reproducing the three live drifts recorded in the diagnosis, now expected to FAIL the invocation: `math add --b 7` ⇒ exit 7 + `--a` required (today: `result: 7`, exit 0); `math add --a abc --b 7` ⇒ exit 7 + type error (today: `result: 7`); `math add --a 3 --b 7 --typo-flag x` ⇒ exit 7 + unknown flag (today: silently ignored). Plus: declared `defaultValue` applied when the flag is absent; `abbr` resolved (`-a` ≡ `--a`); `allowed` values rejected outside the set; positional coerced to its declared type (D5).
  - [x] RED (backward compat, C5): a command registered **without** `params` behaves exactly as today — no enforcement, no crash.
  - [x] Implement the contract check inside the existing command wrapper (`lib/src/module_builder.dart:51-68`), *before* `commandFactory(req)` — the same position `modular_api` pre-validates from `schemaFields` (`usecase_http_handler.dart:20,32`).
  - [x] Failures exit with `ExitCode.validationFailed` (`lib/src/exit_codes.dart`) through the existing `CliOutput.writeError` (`lib/src/module_builder.dart:80-90`), so `--json` mode reports them as structured errors for free.
- **Verify**: `dart test test/enforcement_test.dart` — RED before the wrapper change, green after.
- **Risk**: over-strict rejection of undeclared flags could break existing CLIs — mitigated by C5: enforcement only activates for commands that declare `params`.

## Phase 4 — SDK: the catalog and the native help surface (text)

Implements the core of US-1. The renderer reads the registry from Phase 2 — help becomes a *rendering*, never a source (H1).

- **Entry criteria**: Phases 2–3 green.
- **Covers**: AC-1 (`help`), AC-2 (no args), AC-3 (`--help` / `-h`), AC-5 (developer override), and US-2 AC-5 (global options documented once).
- **Steps**:
  - [x] RED: add `test/help_surface_test.dart` — `help`, no-args, `--help`, `-h` each print the command list to **stdout** with exit **0** (today all four: stderr, 64 — diagnosis F1); the listing shows every registered command with its description; `--json` / `--quiet` appear once under "Global options" and never per command; a developer-registered `help` command wins over the auto one (AC-5).
  - [x] Build the catalog from the registry (routes + descriptions + `CliParam`s + the positional metadata exposed by Phase 1) and a text renderer (aligned, plain — no colour, C9).
  - [x] Auto-register `help` and the empty route `''` for the no-args case — safe only on `cli_router` ≥ 0.0.3 (C3, diagnosis F3); the developer's own `help` registration must take precedence (C6).
  - [x] Intercept `--help` / `-h` in `ModularCli.run` (`lib/src/modular_cli.dart:82-84`) **before** dispatch: with a leading flag no route can ever match (C2, diagnosis F5).
- **Verify**: `dart test test/help_surface_test.dart` — green.
- **Risk**: the auto-registered empty route must not shadow anything; `test/empty_route_test.dart` in `cli_router` (Phase 1) plus the AC-4 case in Phase 7 are the guards.

## Phase 5 — SDK: focused help per command and per module

Implements US-3.

- **Entry criteria**: Phase 4 green.
- **Covers**: US-3 AC-1 (`<cli> <command> --help`), AC-2 (`<cli> <module> --help`), AC-3 (`<cli> bogus --help` ⇒ error path, stderr, 64 — not a false success).
- **Steps**:
  - [x] RED: add `test/focused_help_test.dart` — `math add --help` prints only that command's contract (flags with name, aliases, type, required, default, description; positionals as required) on stdout, exit 0; `math --help` lists every command under the module with its contract, exit 0; `bogus --help` goes to stderr with exit 64.
  - [x] Serve per-command help from inside the command wrapper using `CliRequest.isHelpRequested`, which is already true for a matched `version --help` (diagnosis F7, `cli_request.dart:75-77`) — render and return 0 *before* enforcement runs, so `--help` on an incomplete invocation still helps instead of erroring.
  - [x] Serve per-module help from the mount metadata exposed in Phase 1.
- **Verify**: `dart test test/focused_help_test.dart` — green.

## Phase 6 — SDK: `help --json` (the machine-readable catalog)

Implements US-2 AC-7. Reuses the existing output path (C8).

- **Entry criteria**: Phase 4 green (Phase 5 independent).
- **Covers**: US-2 AC-7 (`help --json` emits the full contract catalog on stdout, exit 0).
- **Steps**:
  - [x] RED: add `test/help_json_test.dart` — `help --json` emits parseable JSON on stdout with exit 0, containing every command with its route, description, and each parameter's name, aliases, type, required, default; and the global options section. Assert it is the machine twin of the text rendering (same command set).
  - [x] Emit through the existing `JsonCliOutput` selected by the `--json` flag (`lib/src/module_builder.dart:52-65`) — no parallel serializer.
- **Verify**: `dart test test/help_json_test.dart` — green.

## Phase 7 — SDK: the error path renders the SDK catalog

Implements D6 end-to-end: the hook from Phase 1 meets the renderer from Phase 4.

- **Entry criteria**: Phases 1, 3 and 4 green.
- **Covers**: AC-4 (unknown command ⇒ error line on stderr + help + exit 64, distinct from the success path).
- **Steps**:
  - [x] RED: add `test/error_path_test.dart` — `bogus` writes `Error: unknown command 'bogus'.` plus the SDK catalog to **stderr** with exit **64** and nothing on stdout; the *same* renderer is used as by `help` (assert the command list matches the stdout help); and an enforcement failure from Phase 3 prints the offending command's own contract (usage + its options) on stderr with exit 7.
  - [x] Inject the SDK's renderer into `CliRouter` via `onNotFound` (Phase 1), so the router no longer prints its own help (`cli_router.dart:167-170`).
- **Verify**: `dart test test/error_path_test.dart` — green.
- **Risk**: the exit-code boundary (0 for help, 64 for unknown, 7 for validation) is the whole point of C1; all three codes are asserted in this phase's test file.

## Phase 8 — Example, docs, specification amendment, and the real dependency

Closes the contract with the outside world.

- **Entry criteria**: Phases 1–7 green.
- **Covers**: issue checklist item 5; AC-1…AC-7 demonstrated end-to-end in `example/`.
- **Steps**:
  - [x] Declare `params` on the example DTOs (`example/modules/math/commands/add.dart`, `example/modules/greetings/commands/hello.dart`, `example/commands/version.dart`) and pass them at registration (`example/modules/math/math_builder.dart:7,13`, `example/modules/greetings/greetings_builder.dart:6`, `example/example.dart:33`) — the example is the demo of the "OPEN API for CLI" property.
  - [x] `pubspec.yaml`: `cli_router: ^0.1.0` (D7 — replaces `^0.0.2`, which by Dart caret semantics could never resolve 0.0.3+, F4) and **remove** `dependency_overrides`; `dart pub get` must resolve 0.1.0 from pub.dev (requires `cli_router` 0.1.0 published — C10, OQ4).
  - [x] `README.md`: document the declared contract, the help surface, `help --json`, and the enforcement semantics; `CHANGELOG.md`: new SDK minor version (new API: `CliParam`, native help, enforcement).
  - [x] Amend `docs/requisitions/20260713-native-help-command/specification.md` §3: delete the exclusion *"changing how arguments are actually parsed at runtime"* — obsoleted by D2/D4 and in direct contradiction with §4 (diagnosis F9).
- **Verify**: `dart test test/example_test.dart` — green (the example test exercises the shipped example end-to-end).

## Final verification

- **Verify (SDK, full suite)**: `dart test` in `C:\Users\44358590\Code\macss\modular_cli_sdk` — every pre-existing test file (`test/integration_test.dart`, `test/cli_output_test.dart`, `test/command_test.dart`, `test/command_exception_test.dart`, `test/exit_codes_test.dart`, `test/input_test.dart`, `test/output_test.dart`, `test/example_test.dart`) plus every file added in Phases 2–7, all green. The untouched `test/integration_test.dart` is the backward-compatibility proof (C5).
- **Verify (router, full suite)**: `cd C:\Users\44358590\Code\macss\cli_router && dart test` — all green, including `test/empty_route_test.dart` and `test/empty_mount_test.dart`.
- **Verify (static)**: `dart analyze` clean and `dart format --set-exit-if-changed .` clean in both repos.
- **Verify (live, the reproduction that opened the issue)**: `dart run example/example.dart` with no args, then `help`, `--help`, `-h` ⇒ help on **stdout**, exit **0**; `bogus` ⇒ error + catalog on **stderr**, exit **64**; `math add --b 7` ⇒ validation error, exit **7**; `help --json` ⇒ parseable catalog on stdout, exit 0.
