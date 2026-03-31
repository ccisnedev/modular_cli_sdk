---
status: ready
repo_mode: mono
module: modular_cli_sdk
stop_at: ready
issue_number: 3
issue_url: https://github.com/macss-dev/modular_cli_sdk/issues/3
branch_name: feature/3-root-commands
created: 2026-03-31
feature_slug: root-commands
feature_name: Root-level command registration for ModularCli
skip_review: true
---

# RUNBOOK – Root-level command registration for ModularCli

## Objective

Add a `command<I, O>()` method to `ModularCli` that registers root-level commands (no module prefix) while reusing the full `Command<I, O>` lifecycle. This enables CLIs like `ape init`, `ape version`, `ape doctor` without requiring a module wrapper. Releases as v0.2.0.

## Scope

**In:**
- `command<I, O>()` method on `ModularCli` — delegates to `ModuleBuilder(moduleName: '', router: _root)`
- Example root commands (`version`) wired into the existing example app
- Integration tests covering root commands (success, `--json`, coexistence with modules, validation failure)
- Updated `README.md` documenting root commands
- Updated `AGENTS.md` reflecting the new API
- Updated `CHANGELOG.md` with v0.2.0 entry
- Version bump to 0.2.0 in `pubspec.yaml`

**Out:**
- Changes to `ModuleBuilder`, `Command`, `Input`, `Output`, `cli_router`
- `--version` as global flag (per ADR-0003: subcommands over flags for independent output)
- Declarative flags (`Flag` class) — remains deferred
- Shell completions, config, auth

## Context

- **Module:** `modular_cli_sdk` | **Location:** `d:\source\macss-dev\modular_cli_sdk\`
- **Kernel dependency:** `cli_router ^0.0.2` — already supports root-level `.cmd()` alongside `.mount()`. Two-phase dispatch: direct routes have priority over mounts.
- **Motivation:** `finite_ape_machine` CLI needs root commands (`ape init`, `ape doctor`, `ape version`). Current `ModularCli` only exposes `.module()`.
- **Design decision:** `moduleName: ''` is safe — the field is not read by any runtime logic in `ModuleBuilder` (verified by grep, 2026-03-31).
- **ADR-0003 (finite_ape_machine):** Everything that produces independent output is a subcommand through `Command<I, O>`, not a global flag.

### Assumptions

- `cli_router` v0.0.2 is stable and does not need modification
- Working tree is clean on `main`
- `gh` CLI is configured for `macss-dev/modular_cli_sdk`

## Decisions Log

- 2026-03-31: `command<I, O>()` delegates to `ModuleBuilder` with `moduleName: ''` — reuses lifecycle, no duplication (Opción A)
- 2026-03-31: Version bump is MINOR (0.1.0 → 0.2.0) — new public API surface, backward-compatible
- 2026-03-31: Root commands have dispatch priority over mounted modules (inherent to `cli_router`)
- 2026-03-31: ADR-0003 — subcommands for independent output, flags only for behavior modifiers

## Execution Plan (TDD Checklist)

**Methodology:** Test Driven Development — Red-Green-Refactor with Review Gate.
**Review mode:** `review` (default) = present tests for user approval before implementing.
**Rules:** mark each sub-step (`[x]`) as completed. Each commit includes code + updated RUNBOOK.

### Test documentation requirements

Every test must have: descriptive name in natural language, docstring explaining what/why/which criterion, explicit preconditions, explicit expected result.

### Review Gate format

1. Summary of the step being tested
2. Code block with complete documented tests
3. Bullet list: test name → purpose
4. Close: **"¿Aprobás estos tests? ¿Querés agregar, quitar o modificar alguno?"**

### Steps

- [x] Step 1: Add `command<I, O>()` to `ModularCli`
  - [x] Write failing test(s) with documentation — root command registration and execution via `ModularCli.command()`
  - [x] 🔍 REVIEW GATE (skipped — skip_review: true)
  - [x] Incorporate feedback
  - [x] Implement minimum code to pass — add method + 3 imports to `modular_cli.dart`
  - [x] Refactor if needed
  - [x] `feat: root-level command registration on ModularCli (#3)` — d87d964

- [x] Step 2: Root command with `--json` output
  - [x] Write failing test(s) with documentation — root command produces valid JSON when `--json` is passed
  - [x] 🔍 REVIEW GATE (skipped — skip_review: true)
  - [x] Passed with Step 1's code (lifecycle already handles `--json`)
  - [x] Committed with Step 1

- [x] Step 3: Root command coexistence with modules
  - [x] Write failing test(s) with documentation — root commands and module commands both resolve correctly in the same CLI
  - [x] 🔍 REVIEW GATE (skipped — skip_review: true)
  - [x] Passed with Step 1's code (cli_router handles dispatch)
  - [x] Committed with Step 1

- [x] Step 4: Root command validation failure
  - [x] Write failing test(s) with documentation — root command with invalid input returns exit code 7
  - [x] 🔍 REVIEW GATE (skipped — skip_review: true)
  - [x] Passed with Step 1's code (lifecycle already validates)
  - [x] Committed with Step 1

- [x] Step 5: Example root command
  - [x] Create `example/commands/version.dart` with `VersionInput`, `VersionOutput`, `VersionCommand`
  - [x] Wire into `example/example.dart` via `cli.command('version', ...)`
  - [x] Add test in `test/example_test.dart` for `['version']` args
  - [x] Verified: `dart run example/example.dart version` and `--json`
  - [x] `example: add root-level version command (#3)` — 9ed1e53

- [x] Step 6: Documentation + version bump
  - [x] Update `README.md` — root commands in Quick Start + Features
  - [x] Update `AGENTS.md` — architecture diagram + Root commands pattern + conventions
  - [x] Update `CHANGELOG.md` — v0.2.0 entry
  - [x] Bump `pubspec.yaml` version to 0.2.0
  - [x] `docs: changelog, readme, agents.md + version bump to 0.2.0 (#3)` — d11220a

- [x] Step 7: Final validation
  - [x] `dart analyze` — zero issues
  - [x] `dart test` — 50 tests, all green
  - [x] `dart format --output=none --set-exit-if-changed .` — 0 changed
  - [x] `dart pub publish --dry-run` — valid (no blocking errors)
  - [x] `chore: dart format (#3)` — 8193553

## Constraints

- **Do not modify `cli_router`** — it is a dependency, not a fork.
- **Do not modify `ModuleBuilder`** — reuse it as-is with `moduleName: ''`.
- **Backward-compatible** — existing `.module()` API is unchanged. No consumer breaks.
- **Coding Manifesto** — apply all rules (R-INT, R-NOM, R-FUN, R-ORD, R-DOC, R-TEC, R-PRO).
- **Zero new dependencies** — only existing `cli_router ^0.0.2`.

## Validation

- `dart pub get` completes without errors
- `dart analyze` reports zero issues
- `dart test` reports all tests green (existing 45 + new root command tests)
- `dart pub publish --dry-run` reports no blocking errors
- `dart run example/example.dart version` prints version info
- `dart run example/example.dart version --json` prints JSON
- `dart run example/example.dart greetings hello --name World` still works (no regression)
- Root commands and module commands coexist without conflict

## Blockers / Open Questions

- [ ] **Pub.dev publish** — confirm before publishing v0.2.0 (carried from v0.1.0 runbook)
