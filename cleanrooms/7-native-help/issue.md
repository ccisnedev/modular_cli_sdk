---
id: issue
issue: "7"
branch: 7-native-help
date: 2026-07-13
---

# Issue #7

<!-- "Issue as code": this .md is the source of truth. Edit and review it here;
     `iq issue publish native-help --plan` shows the `gh issue create` it would
     assemble from the front-matter; `--apply` creates it. -->

# [modular_cli_sdk] Native help: contract catalog, --help/-h/no-args, and help.json

## Context

The SDK ships **no help**. Every deliberate help request falls through to the router's error path:

- `help`, no-args, and `--help`/`-h` all hit `cli_router` 0.0.3's fallback — `Command not found or invalid usage.` + a listing on **stderr**, exit **64** (reproduced against `example/example.dart`). See `cli_router-0.0.3/lib/src/cli_router.dart:167-169`.
- `printHelp`/`listCommands` exist but are **orphaned** — only the error fallback calls them (`ModularCli.printHelp` at `lib/src/modular_cli.dart:87`; `cli_router.dart:78`). The `example.dart` wires no help, so "out of the box" there is none (`example/example.dart:33-43`).
- The listing shows only `route - description`: `ListedCommand` carries **no parameter metadata** (`cli_router-0.0.3/lib/src/route_entry.dart:22-26`), and `ModuleBuilder.command` only accepts `(route, factory, {description})` — flags are parsed imperatively inside each command via `req.flagString(...)` (`lib/src/module_builder.dart:46-53`). The framework therefore **cannot** describe a command's contract even when asked.
- `version -h` ignores `-h` and just runs (exit 0) — no per-command help.

Precedent: the sibling `modular_api` auto-generates its OpenAPI document from the **registered use cases + their declared DTO schemas** (`SchemaField`/`buildSchema`, `RegisteredUseCaseView`). This issue gives the CLI the same property — an **"OpenAPI for CLI"**.

## Scope

- **Contract catalog** — declare each command's parameters (name, aliases, type, required, default, description) once, at registration; the SDK introspects its own command registry to build the catalog. No hand-maintained help.
- **Native help surface** — auto-register so `help`, no-args, `--help`, and `-h` all render help to **stdout** with exit **0**. Preserve the unknown/invalid path on **stderr**, exit **64**.
- **`help.json`** — `help --json` emits the full catalog as JSON, the machine-readable twin (reuse the existing `--json` / `JsonCliOutput` path, `lib/src/module_builder.dart:52-65`).
- **Focused help** — `<cli> <command> --help` and `<cli> <module> --help` render just that command's / module's contract.
- **Developer override** — a `help` command registered by the SDK author wins over the auto one.
- Update `example/`, `README.md`, `CHANGELOG.md` to demonstrate the contract.

## Technical decisions (evidence)

- **Decision**: capture parameters declaratively at registration (extend `ModuleBuilder.command` / `ModularCli.command` with a parameter-descriptor list stored in a registry keyed by route). **Evidence**: today only `route + description` are captured — `lib/src/module_builder.dart:46-50`, `route_entry.dart:22-26`; there is nowhere for the contract to live.
- **Decision**: render help from that registry, mirroring `modular_api`'s registry→OpenAPI path. **Evidence**: `modular_api` `RegisteredUseCaseView` + `SchemaField`/`buildSchema` → `OpenApiPlugin` (`modular_api/code/dart/modular_api/lib/modular_api.dart:29,39,124`).
- **Decision**: help is a **success**, error stays a **failure**. Help entry points → stdout/exit 0; unknown/invalid → stderr/exit 64. **Evidence**: current fallback conflates them at `cli_router.dart:167-169` (exit 64 for everything, incl. bare `--help`).
- **Decision**: `help.json` reuses the existing global `--json` mode. **Evidence**: `JsonCliOutput` already wired per command at `lib/src/module_builder.dart:52-65`.

## Implementation checklist (internal ordering — one PR)

1. **Parameter schema** — descriptor type + registry; `command(...)` accepts declared params. (Enables AC-1…AC-7.)
2. **Help surface** — auto-register `help` + `--help`/`-h` + no-args → stdout/exit 0; keep unknown → stderr/64; developer override. (US-1: AC-1…AC-5.)
3. **Contract render + `help.json`** — text (aligned, global options once, positionals as required) and `--json` catalog. (US-2: AC-1…AC-7.)
4. **Focused help** — `<command|module> --help`; invalid+`--help` → error path. (US-3: AC-1…AC-3.)
5. Example + README + CHANGELOG.

## Acceptance criteria covered

Traces to the full acceptance set of `specification.md` (US-1, US-2 incl. `help.json`, US-3):

- **AC-1** — help entry points (`help` / no-args / `--help` / `-h`) → command list on stdout, exit 0.
- **AC-2** — no-args prints help on stdout, exit 0.
- **AC-3** — `--help` / `-h` print help on stdout, exit 0.
- **AC-4** — unknown command → stderr + help, exit 64 (error path preserved).
- **AC-5** — developer's own `help` overrides the auto one / each parameter shown with description.
- **AC-6** — required / default / aliases / positionals rendered; per-command & per-module focused help.
- **AC-7** — `help --json` emits the full contract catalog (`help.json`) on stdout, exit 0.
