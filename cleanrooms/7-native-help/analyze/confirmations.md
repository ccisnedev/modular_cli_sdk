---
id: confirmations
title: "Confirmations"
date: 2026-07-13
status: active
tags: [confirmations, findings]
---

# Confirmations

> Living document. Update as findings are confirmed, revised, or invalidated.
> Format: ## F<N>: <title> — CONFIRMED|REVISED|INVALIDATED

## F1: The four help entry points all land on the router's error path — CONFIRMED

Live reproduction against the SDK example (`dart run example/example.dart <args>`), with the
`cli_router` version actually locked in `pubspec.lock:52-59` (**0.0.2**, not 0.0.3):

| args | stdout | stderr | exit |
|------|--------|--------|------|
| _(none)_ | empty | `Command not found or invalid usage.` + listing | 64 |
| `help` | empty | same | 64 |
| `--help` | empty | same | 64 |
| `-h` | empty | same | 64 |
| `bogus` | empty | same | 64 |
| `version -h` | `version: 0.2.0` | empty | 0 |

Origin of the behaviour: `cli_router-0.0.3/lib/src/cli_router.dart:166-170` (fallback writes to
stderr and returns `64`; identical in 0.0.2). `version -h` proves `-h` is parsed as a flag and then
ignored: nothing in `module_builder.dart:51-68` consults it.

## F2: `printHelp` / `listCommands` are orphaned — CONFIRMED

`ModularCli.printHelp` (`lib/src/modular_cli.dart:87-89`) is public but never called by the SDK;
the only caller of the router's own `printHelp` is the not-found fallback
(`cli_router-0.0.3/lib/src/cli_router.dart:169`). `example/example.dart:33-43` wires no help, so a
CLI built with the SDK ships none.

## F3: On the locked cli_router (0.0.2) the empty route `''` is a catch-all — CONFIRMED

Throwaway probe (scratchpad `probe/bin/probe.dart`: a router with `cmd('')` + `cmd('version')`):

| args | cli_router 0.0.2 | cli_router 0.0.3 |
|------|------------------|------------------|
| _(none)_ | `''` route hit, exit 0 | `''` route hit, exit 0 |
| `--help` | `''` route hit (`flags={help:true}`), exit 0 | fallback, stderr, exit 64 |
| `bogus` | **`''` route hit, exit 0** | fallback, stderr, exit 64 |
| `version --help` | handler hit, `isHelpRequested=true` | handler hit, `isHelpRequested=true` |

Consequence: under 0.0.2, using `cmd('')` to satisfy AC-2 (no-args ⇒ stdout/0) also swallows the
unknown command and destroys AC-4 (unknown ⇒ stderr/64). The 0.0.3 guard
(`cli_router.dart:113-114`, `if (j == 0 && args.isNotEmpty) continue`) is what separates them —
see `cli_router-0.0.3/CHANGELOG.md` "[0.0.3] Empty route `''` no longer acts as catch-all".

## F4: 0.0.3 is blocked by the SDK's own constraint — CONFIRMED

`pubspec.yaml` declares `cli_router: ^0.0.2`, which in Dart caret semantics for `0.0.x` means
`>=0.0.2 <0.0.3`. `dart pub upgrade --dry-run` reports *"1 package has newer versions incompatible
with dependency constraints"*, and `pubspec.lock` stays at `0.0.2`. The sibling repo
`C:\Users\44358590\Code\macss\cli_router` is already at `version: 0.0.3` (commit `a6718dd fix: empty
route must not act as catch-all when args is non-empty`) and published on pub.dev.

## F5: Flag-only invocations (`--help`, `-h`) are structurally unroutable in 0.0.3 — CONFIRMED

With `--help` as the only arg, `_indexOfFirstFlag` returns 0 → `maxRouteTokens = 0`
(`cli_router.dart:108-109`); the only candidate is `j = 0`, which the 0.0.3 guard rejects because
`args` is not empty (`cli_router.dart:113-114`). Confirmed by the F3 probe: `--help` and `-h` reach
the fallback. Therefore no *route* can serve root-level `--help`/`-h`; they must be handled before
dispatch (in `ModularCli.run`, `lib/src/modular_cli.dart:82-84`) or by a router-level hook.

## F6: The framework cannot describe a command's contract — CONFIRMED

`ListedCommand` carries only `command` + `description` (`cli_router-0.0.3/lib/src/route_entry.dart:22-26`),
and `ModuleBuilder.command` accepts only `(route, factory, {description})`
(`lib/src/module_builder.dart:46-50`). Parameters are parsed imperatively and defaulted inside each
Input factory — e.g. `req.flagInt('a') ?? 0` (`example/modules/math/commands/add.dart:12-13`),
`req.flagString('name') ?? 'World'` (`test/integration_test.dart:14-15`). The default `0` / `'World'`
exists only in the factory body; no declaration holds it.

Meanwhile the router *does* know positionals structurally (`_Segment.isParam`,
`cli_router-0.0.3/lib/src/path_pattern.dart:50-60`) and already parses aliases, `--k=v`, `-abc`
bundles and `--no-x` negation (`cli_router-0.0.3/lib/src/flags_parser.dart:30-60`) — but
`listCommands` discards all of it (`cli_router.dart:65-75`).

## F7: Reusable seams already exist — CONFIRMED

- `CliRequest.isHelpRequested` (`cli_router-0.0.3/lib/src/cli_request.dart:75-77`) already means
  `--help` / `-h` / a leading `help` positional; the F3 probe shows a matched command receives it
  (`version --help` ⇒ `isHelpRequested=true`), so per-command help can be served from inside
  `ModuleBuilder.command`'s wrapper (`lib/src/module_builder.dart:51-68`).
- `Input.schemaFields` (`lib/src/input.dart:33`) and `Output.schemaFields` (`lib/src/output.dart:35`)
  already exist, typed `List<dynamic>?` and documented as *"reserved for future schema export"* — an
  empty seat waiting for the contract type.
- `--json` already selects `JsonCliOutput` per command (`lib/src/module_builder.dart:52-65`), so
  `help --json` (`help.json`) reuses the existing output path.

## F8: modular_api's precedent is enforcement, not just documentation — CONFIRMED

In `modular_api` the DTO declares the schema and the **framework's handler wrapper** both documents
and enforces it:

- OpenAPI is generated from the registered DTO instance: `r.inputExample.toSchema()`
  (`modular_api/code/dart/modular_api/lib/src/openapi/openapi.dart:255`).
- The same `schemaFields` pre-validates every request before the DTO factory runs:
  `final preValidationFields = inputExample?.schemaFields;` → `validateJsonFields(data, preValidationFields)`
  (`modular_api/code/dart/modular_api/lib/src/core/usecase/usecase_http_handler.dart:20,32`).
- Registration carries the DTO examples, not the router:
  `usecase(command, factory, {required Input inputExample, required Output outputExample, ...})`
  (`modular_api/code/dart/modular_api/lib/src/core/modular_api.dart:315-322`).

Critically, `shelf_router` knows nothing about schemas — the contract lives in the DTO and in the
framework layer. And `SchemaField` (`.../src/core/schema/field.dart:28-45`) models a JSON payload:
`name, type, description, required, nullable, items, example`. It has **no** short alias, no default
value, no positional/flag kind, no negatable/repeatable/allowed-values — i.e. it is not, as-is, a CLI
invocation contract.

## F9: The specification contradicts itself on parsing authority — CONFIRMED

- Business rule: *"each command declares its parameters once, at registration, and the framework
  introspects its own command registry… Help and actual argument parsing therefore read from a single
  declared source and cannot drift"* (`docs/requisitions/20260713-native-help-command/specification.md`, §4 Rules).
- Explicit scope exclusion: *"Changing how arguments are actually parsed at runtime (this is about
  describing the contract, not re-parsing it)"* (same file, §3 "Does NOT include").

A purely descriptive catalog cannot honour the "cannot drift" rule while defaults live in factory
bodies (F6). **Resolved by the user in ANALYZE (2026-07-13): the declaration governs — declaring is
parsing.** The §3 exclusion is therefore obsolete and must be corrected in the specification.

## F10: The ecosystem boundary is open — CONFIRMED (user decision)

User decision in ANALYZE (2026-07-13): `cli_router` may and *should* evolve, delegating to each
component what belongs to it (repo: `C:\Users\44358590\Code\macss\cli_router`, currently 0.0.3).
This lifts the dead end created by F3/F4/F5.

## F11: Contract ownership — DTO-centric, enforced by the SDK — CONFIRMED (user decision)

User decision in ANALYZE (2026-07-13), consistent with F8: the parameter contract is declared by the
DTO (`Input`) and enforced by the SDK's command wrapper — `cli_router` stays a transport that owns
routing/parsing/introspection, never the contract type. This preserves the
`shelf_router : modular_api :: cli_router : modular_cli_sdk` symmetry.
