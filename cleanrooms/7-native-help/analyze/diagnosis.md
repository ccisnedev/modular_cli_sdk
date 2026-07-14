---
id: diagnosis
title: "Diagnosis"
date: 2026-07-13
status: active
tags: [diagnosis, evidence-first]
---

# Diagnosis

**Issue:** #7 — [modular_cli_sdk] Native help: contract catalog, `--help`/`-h`/no-args, and `help.json`
**Branch:** 7-native-help

## Problem defined

A CLI built with `modular_cli_sdk` ships **no help**. Every deliberate help request — `help`,
no-args, `--help`, `-h` — is indistinguishable from a mistake: all four print to **stderr** and exit
**64**. Underneath that symptom lies a structural gap: the framework has **no representation of a
command's contract**. Registration captures only `route + description`, so even if help were wired it
could not describe how to invoke anything. Parameters live imperatively inside each `Input` factory
(`req.flagInt('a') ?? 0`), which is also where defaults hide — so any help text would be a second,
hand-maintained truth that drifts from the code that actually parses.

## Evidence

- All four help entry points fail identically (live run: `dart run example/example.dart` with no args, `help`, `--help`, `-h` → empty stdout, `Command not found or invalid usage.` on stderr, exit 64), and the unknown command `bogus` yields the *same* output — success and error are indistinguishable; full table in `cleanrooms/7-native-help/analyze/confirmations.md` (F1).
- The behaviour originates in the router's not-found path — `stderr.writeln(...)` + `printHelp(stderr)` + `return 64` — at `cli_router-0.0.3/lib/src/cli_router.dart:167-170`, identical in 0.0.2.
- `version -h` exits 0 and just runs the command: `-h` is parsed as a flag and then ignored, because nothing in `lib/src/module_builder.dart:51-68` consults it — there is no per-command help.
- Help is orphaned code: `ModularCli.printHelp` at `lib/src/modular_cli.dart:87-89` has no caller inside the SDK, and the example wires none (`example/example.dart:33-43`).
- The framework cannot describe a contract: `ListedCommand` holds only `command` + `description` (`cli_router-0.0.3/lib/src/route_entry.dart:22-26`) while `ModuleBuilder.command` accepts only `(route, factory, {description})` (`lib/src/module_builder.dart:46-50`).
- Parameters and their defaults exist only inside factory bodies: `req.flagInt('a') ?? 0` at `example/modules/math/commands/add.dart:12-13` and `req.flagString('name') ?? 'World'` at `test/integration_test.dart:14-15` — no declaration holds them.
- The router already owns real invocation metadata and then discards it: positional segments (`_Segment.isParam`, `cli_router-0.0.3/lib/src/path_pattern.dart:50-60`) plus alias / `--k=v` / `-abc` / `--no-x` parsing (`cli_router-0.0.3/lib/src/flags_parser.dart:30-60`), none of which survives `listCommands` (`cli_router-0.0.3/lib/src/cli_router.dart:65-75`).
- Under the locked `cli_router` 0.0.2 the empty route `''` is a catch-all — a throwaway probe registering `cmd('')` (scratchpad `probe/bin/probe.dart`) matches `bogus` with exit 0, which would destroy AC-4 (confirmations F3, `cleanrooms/7-native-help/analyze/confirmations.md:38-52`).
- Under 0.0.3 the guard `if (j == 0 && args.isNotEmpty) continue` at `cli_router-0.0.3/lib/src/cli_router.dart:113-114` restricts `''` to genuinely empty args — the change logged as "[0.0.3] Empty route `''` no longer acts as catch-all" in `cli_router-0.0.3/CHANGELOG.md:8-10`.
- 0.0.3 is currently unreachable: `pubspec.yaml:19` pins `cli_router: ^0.0.2` (Dart caret on `0.0.x` ⇒ `>=0.0.2 <0.0.3`), `pubspec.lock:52-59` resolves 0.0.2, and `dart pub upgrade --dry-run` reports "1 package has newer versions incompatible with dependency constraints".
- Root-level `--help` / `-h` are structurally unroutable: a leading flag forces `maxRouteTokens = 0` (`cli_router-0.0.3/lib/src/cli_router.dart:108-109`) and the only candidate `j = 0` is rejected by the 0.0.3 guard — the probe confirms both fall through to the fallback (confirmations F5).
- Reusable seams exist: `CliRequest.isHelpRequested` (`cli_router-0.0.3/lib/src/cli_request.dart:75-77`) is already true for a matched `version --help` (probe), `Input.schemaFields` (`lib/src/input.dart:33`) and `Output.schemaFields` (`lib/src/output.dart:35`) sit empty as "reserved for future schema export", and `--json` already selects `JsonCliOutput` (`lib/src/module_builder.dart:52-65`).
- The `modular_api` precedent is enforcement, not decoration: OpenAPI is generated from the registered DTO instance (`r.inputExample.toSchema()`, `modular_api/code/dart/modular_api/lib/src/openapi/openapi.dart:255`) and that same `schemaFields` pre-validates every request before the DTO factory runs (`modular_api/code/dart/modular_api/lib/src/core/usecase/usecase_http_handler.dart:20,32`).
- In `modular_api` the contract travels with the DTOs at registration — `usecase(command, factory, {required Input inputExample, required Output outputExample, ...})` at `modular_api/code/dart/modular_api/lib/src/core/modular_api.dart:315-322` — so `shelf_router` never learns about schemas; the transport stays contract-free.
- `SchemaField` models a JSON payload (`name, type, description, required, nullable, items, example`) at `modular_api/code/dart/modular_api/lib/src/core/schema/field.dart:28-45`, with no short alias, no default, no flag/positional kind and no negatable/repeatable/allowed-values — it cannot express a CLI invocation contract as-is.
- The specification contradicts itself — §4 Rules demands that help and argument parsing "read from a single declared source and cannot drift" while §3 excludes "changing how arguments are actually parsed at runtime" — both in `docs/requisitions/20260713-native-help-command/specification.md` (confirmations F9).
- Help is documented nowhere in the repo: `grep -n help README.md CHANGELOG.md AGENTS.md` returns no match.

## Hypotheses

- **H1 (root cause).** The absence of help is not a missing feature but a missing *model*: the
  framework has no contract type, so the only thing it can print is the route list the router keeps
  for its error path. Introducing a declared command contract (name, kind flag/option/positional,
  type, aliases, required, default, allowed values, description) is the enabling change; `help`,
  `help.json` and focused help are then **renderings** of it. Licensed by F6; mirrors how
  `modular_api` renders OpenAPI from `schemaFields` (F8).
- **H2 (layering).** The correct delegation is `shelf_router : modular_api :: cli_router :
  modular_cli_sdk`. `cli_router` owns *invocation* — routes, positionals, flag parsing, route
  introspection and the not-found path, all of which it already implements and then throws away (F6).
  `modular_cli_sdk` owns the *contract* — the DTO-declared parameter schema, its enforcement in the
  command wrapper, and the rendering of help/`help.json` through the existing `CliOutput` (F7, F8).
  Putting the contract type inside `cli_router` would couple the transport to the SDK's model, which
  `modular_api` deliberately does not do (F8).
- **H3 (why AC-2 and AC-4 collide today).** No-args and unknown-command can only be separated with the
  0.0.3 catch-all guard; on the locked 0.0.2, serving no-args via the empty route silently turns
  unknown commands into successes (F3). The dependency bump is a precondition, not a preference (F4).
- **H4 (where the entry points must be intercepted).** `help` (a word) is routable; no-args is routable
  only under ≥ 0.0.3; `--help`/`-h` alone are **not routable at all** (F5) — they must be handled
  before dispatch or via a new router hook. The unknown-command path likewise prints the router's own
  listing straight to stderr with no hook (`cli_router.dart:166-170`), so rendering the SDK's catalog
  there requires `cli_router` to expose a not-found/help hook instead of hard-coding `printHelp`.
- **H5 (drift is already latent).** Because defaults live in factory bodies (F6), a
  *descriptive-only* catalog would be born divergent: help could claim `--a` is required with default
  `0` while `AddInput.fromCliRequest` silently coerces a missing flag to `0`. Only a declaration that
  also governs parsing satisfies the §4 "cannot drift" rule.

## Decisions taken (user, ANALYZE 2026-07-13)

- **D1 — The ecosystem may evolve.** `cli_router` (`C:\Users\44358590\Code\macss\cli_router`, at
  0.0.3) is in scope; each component must own what belongs to it. Consequence: the SDK will consume a
  `cli_router` ≥ 0.0.3 (widening `pubspec.yaml`'s `^0.0.2`, F4) and `cli_router` may gain what only it
  can provide — route/positional introspection and a not-found/help hook (H4).
- **D2 — Declaring is parsing.** The parameter declaration is the single source of truth: it governs
  type coercion, alias resolution, defaults and required-ness at runtime, and help/`help.json` are
  rendered from that same source. This resolves the specification contradiction in favour of §4 and
  **obsoletes the §3 exclusion** ("not re-parsing it"), which must be corrected in
  `docs/requisitions/20260713-native-help-command/specification.md`.
- **D3 — DTO-centric contract, enforced by the SDK.** The contract is declared by the `Input` DTO
  (filling the existing `schemaFields` seat, `lib/src/input.dart:33`) and enforced by the SDK's
  command wrapper (`lib/src/module_builder.dart:51-68`) — the exact position `modular_api` uses
  (`usecase_http_handler.dart:20,32`). The contract type is CLI-native (kind, alias, default, allowed
  values, negatable, repeatable), **not** a copy of `SchemaField` (F8), and it does not live in
  `cli_router`.
- **D4 — Enforcement ships in this PR (closes OQ2).** The declared contract governs runtime parsing:
  alias resolution, required-ness, type coercion, declared defaults, allowed values, and rejection of
  undeclared flags — failing with `ExitCode.validationFailed` (`lib/src/exit_codes.dart`) through the
  existing `CliOutput.writeError` path (`lib/src/module_builder.dart:80-90`). Without it the catalog
  is a second truth: today `dart run example/example.dart math add --b 7` prints `result: 7` with exit
  **0** (missing operand silently defaulted), `math add --a abc --b 7` prints `result: 7` (unparsable
  int silently defaulted), and `math add --a 3 --b 7 --typo-flag x` ignores the undeclared flag — all
  reproduced live in ANALYZE. Help rendered from a contract that the runtime does not enforce would
  document behaviour the binary does not have, violating specification §4.
- **D5 — Positional enforcement is split (closes OQ1).** `cli_router` owns presence and arity: a route
  such as `show <id>` simply does not match without the token
  (`cli_router-0.0.3/lib/src/path_pattern.dart:26-45`), so "required" is already structurally
  guaranteed. The SDK owns type coercion and allowed values for the positional, from the same
  declaration used for flags. No new router API is needed for this.
- **D6 — The error path renders the SDK catalog via a router hook (closes OQ3).** `cli_router`
  hard-coding its own `printHelp` to stderr (`cli_router-0.0.3/lib/src/cli_router.dart:167-170`) is a
  layering violation — the router decides *what* failed to match, not *how* it is presented to a
  human; the transport analogy `shelf_router : modular_api :: cli_router : modular_cli_sdk` (H2)
  requires it. `cli_router` therefore gains an injectable not-found hook (`onNotFound`), keeping its
  current output as the default when no hook is supplied (additive, non-breaking). The SDK injects a
  renderer so the unknown-command path and the validation-failure path emit the *same* catalog as
  `help` — only the sink (stderr) and the exit code (64 / 7) differ. This is the only way the
  enforcement errors of D4 can print the offending command's contract.
- **D7 — `cli_router` releases as 0.1.0, not 0.0.4.** In Dart, `^0.0.z` resolves to `>=0.0.z <0.0.(z+1)`,
  i.e. the caret on a `0.0.x` version permits **no** upgrade at all — which is precisely what pinned
  the SDK to 0.0.2 and blocked the 0.0.3 fix (F4, `pubspec.yaml:19`). Since D6's hook and the route
  introspection of H2 are additive with the default behaviour preserved, a minor bump to **0.1.0** is
  the correct semver step, and the SDK depends on `^0.1.0` (`>=0.1.0 <0.2.0`) so future compatible
  patches resolve without another pubspec edit.

## Constraints

- **C1.** Help is a success, error stays a failure: help entry points ⇒ stdout / exit **0**; unknown
  or invalid usage ⇒ stderr / exit **64** (AC-1…AC-4). Today both are conflated at
  `cli_router-0.0.3/lib/src/cli_router.dart:166-170`.
- **C2.** `--help` / `-h` with no route tokens cannot be served by any route (F5): interception must
  happen in `ModularCli.run` (`lib/src/modular_cli.dart:82-84`) or via a new `cli_router` hook.
- **C3.** The empty route `''` is only safe on `cli_router` ≥ 0.0.3 (F3); on 0.0.2 it silently turns
  unknown commands into exit-0 successes.
- **C4.** `pubspec.yaml`'s `cli_router: ^0.0.2` must be widened or 0.0.3+ can never resolve (F4).
- **C5.** Backward compatibility: `ModuleBuilder.command` / `ModularCli.command` are public API with
  live callers (`example/`, `test/integration_test.dart`); the contract declaration must be additive
  and optional, and a command without a declared contract must keep working with degraded help
  (route + description), never a crash.
- **C6.** A developer-registered `help` command must win over the auto-registered one (AC-5).
- **C7.** Global options (`--json`, `--quiet`/`-q` — `lib/src/module_builder.dart:52-53`) are rendered
  once in a shared section, never repeated per command (US-2 AC-5).
- **C8.** `help --json` must reuse the existing `JsonCliOutput` path
  (`lib/src/module_builder.dart:52-65`), not a parallel serializer (US-2 AC-7).
- **C9.** Out of scope per specification §3: shell completions, man pages, ANSI colour/TUI, i18n.
- **C10.** Delivery couples two repos: a `cli_router` change must be released (0.0.4) before the SDK
  can depend on it — the SDK release cannot precede it.

## Scope

**Enters:** a CLI-native, DTO-declared parameter contract enforced by the SDK; a native help surface
(`help`, no-args, `--help`/`-h`) on stdout with exit 0, with the error path preserved on stderr with
exit 64; the machine-readable `help --json` catalog; focused help per command and per module; the
developer override; the `cli_router` additions only the router can provide (route/positional
introspection, not-found/help hook, ≥ 0.0.3 semantics); and updates to `example/`, `README.md`,
`CHANGELOG.md`.

**Does not enter:** shell completions, man/PDF generation, colour/TUI, i18n (specification §3), and any
redesign of the `Command`/`Output` lifecycle beyond what the contract requires.

## Open Questions

- **OQ1 — CLOSED** by D5: positional presence/arity stays in `cli_router` (already structural), type
  and allowed-values coercion belongs to the SDK.
- **OQ2 — CLOSED** by D4: enforcement ships in this PR, together with the help surface. Consequence
  for PLAN: `docs/requisitions/20260713-native-help-command/specification.md` §3 must be amended —
  the exclusion "changing how arguments are actually parsed at runtime" is obsolete, superseded by §4.
- **OQ3 — CLOSED** by D6: the SDK renders the catalog on the error path through an injectable
  `onNotFound` hook in `cli_router`; the router's hard-coded stderr help
  (`cli_router-0.0.3/lib/src/cli_router.dart:167-170`) becomes the default only when no hook is given.
- **OQ4 (new, for PLAN).** Release ordering across the two repos (C10): `cli_router` 0.1.0 (D7) must
  be published before `modular_cli_sdk` can depend on `^0.1.0`. PLAN must state whether the SDK work
  proceeds against a local `path:`/`dependency_overrides` pin while 0.1.0 is being released, and what
  the final `pubspec.yaml` state must be before merge.

## References

- `cleanrooms/7-native-help/analyze/confirmations.md` — F1…F11, with the reproduction table and the
  0.0.2 vs 0.0.3 probe.
- `cleanrooms/7-native-help/issue.md` — issue #7 as registered.
- `docs/requisitions/20260713-native-help-command/specification.md` — US-1…US-3, AC-1…AC-7, §3 scope,
  §4 rules.
