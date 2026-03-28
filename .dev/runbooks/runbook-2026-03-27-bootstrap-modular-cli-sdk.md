# RUNBOOK — Bootstrap modular_cli_sdk v0.1.0

## Objective

Create the Dart package `modular_cli_sdk` v0.1.0 — an SDK/framework for modular CLIs that uses `cli_router` as the routing engine and exposes a high-level contract symmetric with `modular_api`: `Command<I,O>`, `Input`, `Output`, `ModularCli`, `ModuleBuilder`.

v0.1.0 establishes the **public contract** of the framework: the abstractions consumers will depend on. What ships here defines the API shape; everything added later is an additive layer.

## Scope

**In:**
- Package scaffold (`pubspec.yaml`, `analysis_options.yaml`, barrel export)
- `ModularCli` — entry point (analogous to `ModularApi`)
- `ModuleBuilder` — per-module command registration (analogous to `ModuleBuilder` in modular_api)
- `Command<I, O>` — unit of work (analogous to `UseCase<I, O>`)
- `Input` — inbound DTO from flags/params
- `Output` — outbound DTO with `exitCode`
- `CommandException` — structured error (`code`, `message`, `details`, `isRetryable`)
- Exit code catalog — semantic constants
- `CliOutput` — output formatting abstraction (JSON + plain text)
- Basic TTY detection (`stdout.hasTerminal`)
- Minimal global flags (`--json`, `--quiet`)
- Error middleware (catch → format → exitCode)
- Working example (2 modules, 3–4 commands)
- Unit tests + integration tests
- `README.md`, `AGENTS.md`, `CHANGELOG.md`

**Out:**
- Advanced `--format` (table/csv/tsv), ANSI-colored tables
- `--jq` inline
- Declarative `Flag` class, schema export, automatic flag validation
- Shell completions (bash/zsh/fish/pwsh)
- `CliConfig` with layered precedence, persistent context, profiles
- Authentication, interactivity (`--yes`, prompts), `--non-interactive`
- Command aliases

## Context

- Module: `modular_cli_sdk`
- Location: `d:\source\macss-dev\modular_cli_sdk\`
- Kernel dependency: `cli_router ^0.0.2` (routing, GNU flags, middleware, mount)
- Reference architecture: `modular_api` v0.4.4 (Dart) — deliberate symmetry
- Full spec: `helpdesk/help/code/cli/doc/modular_cli_sdk.md` (45 requirements, 5 phases)
- v0.1.0 covers 26/45 requirements (58%): full core + errors + exit codes + basic output
- Methodology: **Test Driven Development (TDD)**

### Assumptions

- `cli_router` v0.0.2 is published on pub.dev and stable
- Dart SDK >=3.8.1 is available
- `gh` CLI is configured to create issues in `macss-dev/modular_cli_sdk`
- Naming convention follows the MACSS ecosystem: `modular_*`

### Key design decisions (from spec analysis)

1. **Handlers return data, they don't write strings** — the framework formats based on flags/TTY
2. **Deliberate symmetry with modular_api** — same mental model, different transport
3. **cli_router as a dependency, not a fork** — two separate packages at different abstraction levels

## Decisions Log

- 2026-03-27: v0.1.0 scope defined as full Phase 0 + selective Phase 2 (errors + exit codes) + basic output (JSON/text + TTY)
- 2026-03-27: `Command<I,O>.execute()` returns `Future<O>` (does not assign to a field) — consistent with modular_api
- 2026-03-27: `Input.fromCliRequest(CliRequest req)` as factory — deserializes from flags/params
- 2026-03-27: Declarative flags (`Flag` class) deferred to v0.2.0 — v0.1.0 uses ad-hoc flags inherited from cli_router
- 2026-03-27: Input and Output use generative constructors (`extends`, not `implements`) so subclasses inherit default `schemaFields`
- 2026-03-27: Error middleware is inline in `ModuleBuilder._executeCommand()` — no separate middleware file needed for v0.1.0

## Test Review Mode

- **Mode**: `skip`
- `review`: at each step, tests are presented to the user for approval before implementation begins. The user may add, remove, or modify tests.
- `skip`: the agent writes tests and proceeds to implementation without pausing for review.

## Execution Plan (TDD Checklist)

Each step follows the Red-Green-Refactor cycle. Mode: `skip` (no review gates).
All steps completed in a single session on 2026-03-27.

### Step 1: Package scaffold + barrel export ✅

- [x] `pubspec.yaml`, `analysis_options.yaml`, `lib/modular_cli_sdk.dart`
- [x] `dart pub get` + `dart analyze` — zero issues

### Step 2: Exit code catalog ✅

- [x] `test/exit_codes_test.dart` — 3 tests
- [x] `lib/src/exit_codes.dart` — `ExitCode` class with 8 static constants

### Step 3: CommandException — structured error ✅

- [x] `test/command_exception_test.dart` — 6 tests
- [x] `lib/src/command_exception.dart`

### Step 4: Output — outbound DTO ✅

- [x] `test/output_test.dart` — 3 tests
- [x] `lib/src/output.dart`

### Step 5: Input — inbound DTO ✅

- [x] `test/input_test.dart` — 3 tests
- [x] `lib/src/input.dart`

### Step 6: Command\<I, O\> — unit of work ✅

- [x] `test/command_test.dart` — 6 tests
- [x] `lib/src/command.dart`

### Step 7: CliOutput — output formatting abstraction ✅

- [x] `test/cli_output_test.dart` — 10 tests (JSON + Text)
- [x] `lib/src/cli_output.dart` — abstract interface
- [x] `lib/src/cli_output_json.dart` — JSON implementation
- [x] `lib/src/cli_output_text.dart` — plain text implementation

### Step 8: ModuleBuilder — command registration ✅

- [x] `lib/src/module_builder.dart` — wires factory → validate → execute → format
- [x] Tested via integration tests

### Step 9: ModularCli — entry point ✅

- [x] `lib/src/modular_cli.dart` — orchestrates modules, global flags, middleware
- [x] Tested via integration tests

### Step 10: Error middleware ✅

- [x] Error handling integrated into `ModuleBuilder._executeCommand()`
- [x] Catches `CommandException`, formats via `CliOutput`, returns `exitCode`
- [x] Validation errors produce `ExitCode.validationFailed` (7)

### Step 11: Barrel export + AGENTS.md ✅

- [x] `lib/modular_cli_sdk.dart` — exports all 10 public types
- [x] `AGENTS.md` — framework guide for AI agents

### Step 12: Integration test — full pipeline ✅

- [x] `test/integration_test.dart` — 8 tests covering all modes and scenarios
- [x] All exit codes verified: 0, 1, 7, 64

### Step 13: Working example ✅

- [x] `example/example.dart` — 2 modules (greetings + math), 3 commands
- [x] `test/example_test.dart` — 3 tests

### Step 14: README + CHANGELOG + documentation ✅

- [x] `README.md` — badges, features, quick start, architecture overview
- [x] `CHANGELOG.md` — v0.1.0 entry with all features
- [x] `doc/architecture.md` — stack diagram, class correspondence table

### Step 15: Final validation + publish prep ✅

- [x] `dart analyze` — zero issues
- [x] `dart test` — 45 tests, all green
- [x] `dart format --output=none --set-exit-if-changed .` — 0 changed
- [x] `dart pub publish --dry-run` — valid (only warning: uncommitted files)

## Constraints

- **Do not break cli_router** — it is a dependency, not a fork. Its code must not be modified.
- **Symmetry with modular_api** — same mental model (`module → command → input → execute → output`). Aligned names and patterns.
- **Zero additional dependencies** (only `cli_router`). The package must stay lightweight.
- **Dart SDK >=3.8.1** — match the minimum from cli_router.
- **Coding Manifesto** — apply all rules: R-INT, R-NOM, R-FUN, R-ORD, R-DOC, R-TEC, R-PRO.
- **Declarative flags deferred** — v0.1.0 uses ad-hoc flags inherited from cli_router. The `Flag` class belongs to Phase 3 (v0.2.0).
- **No application logic** — auth, config persistence, and profiles are the consumer's responsibility. The framework only provides the enabling patterns.

## Validation

- `dart pub get` completes without errors
- `dart analyze` reports zero issues
- `dart test` reports all tests green
- `dart pub publish --dry-run` reports no blocking errors
- The example `example/example.dart` runs correctly with:
  - `dart run example/example.dart greetings hello --name World`
  - `dart run example/example.dart greetings hello --name World --json`
  - `dart run example/example.dart greetings hello --name World --quiet`
  - `dart run example/example.dart unknown-command` → exit code 64
- A consumer can build a working CLI using only the exported public types

## Rollback / Safety

- Each step has its own commit — individually revertible
- The package is new; there are no existing consumers to break
- `cli_router` is not modified — rollback does not affect the kernel

## Blockers / Open Questions

- [x] **Does `cli_router` need to expose anything else?** — No. `CliRequest` exposes flags, params, positionals, and I/O sinks — sufficient for all Input deserialization.
- [x] **Does `execute()` return `Future<O>` or `Future<void>` with field assignment?** — Returns `Future<O>` (confirmed in Step 6).
- [ ] **Pub.dev or GitHub Packages only?** — Assume pub.dev (public). Confirm before publishing.
- [x] **Path dependency for local cli_router development?** — Not needed. `cli_router ^0.0.2` from pub.dev works as-is.
