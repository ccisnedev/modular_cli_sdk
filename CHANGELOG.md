# Changelog
All notable changes to this project will be documented in this file.

The format loosely follows [Keep a Changelog](https://keepachangelog.com/)
and the project adheres to [Semantic Versioning](https://semver.org/).

## 0.3.1

### Fixed

- **A registered root route owns the empty invocation.** `ModularCli` rewrote bare `<cli>` into `help` unconditionally, on the assumption that no route can serve the empty invocation. A CLI that registers one — a dashboard, a status screen, a banner — had that command silently replaced by the help. The rewrite now applies only when nothing claims the empty route; a CLI without a root route is unaffected
- **The help listing names the root route.** Having no token to type, it rendered as a description hanging off a blank column. It is now listed as `(no arguments)` — the only way it can be invoked

### Added

- The example registers a **root command**, so the bare invocation is exercised. Its absence is why no test could see either defect above

## 0.3.0

### Added

- **Command contract** — `CliParam` declares a command's parameters (kind, type, short alias, required, default, allowed values) on its `Input`, and `command(...)` accepts them via `params:` ([#7](https://github.com/macss-dev/modular_cli_sdk/issues/7))
- **Native help** — `help`, no arguments, `--help` and `-h` print the command list to **stdout** with exit **0**. Unknown or invalid usage stays on **stderr** with exit **64**. A `help` command registered by the developer overrides the built-in one
- **Focused help** — `<command> --help` renders that command's contract; `<module> --help` renders every command in the module
- **`help --json`** — the full contract catalog as JSON (`help.json`), the machine twin of the text help, through the existing `JsonCliOutput`
- **Enforcement** — the declaration governs parsing: aliases resolved, declared defaults applied, values coerced to their declared type, undeclared options and values outside `allowed` rejected with exit **7**. A rejected invocation is answered with the contract it failed to honour

### Changed

- `Input.schemaFields` is now typed `List<CliParam>?` (was `List<dynamic>?`, documented as reserved)
- Requires `cli_router: ^0.1.0`, which adds the `onNotFound` hook the SDK uses to render its own catalog on the error path, and route metadata for positionals

### Notes

- Commands that declare no `params` behave exactly as before: not described in help, not enforced

## 0.2.1

### Added

- `Output.toText()` — override for custom text formatting ([#5](https://github.com/macss-dev/modular_cli_sdk/issues/5))
  - When non-null, `TextCliOutput` uses this value directly instead of iterating `toJson()` fields
  - JSON mode is unaffected — it always uses `toJson()`
  - Non-breaking: defaults to `null`, preserving existing behavior

## 0.2.0

### Added

- `ModularCli.command<I, O>()` — register root-level commands without a module prefix
- Root commands reuse the full `Command<I, O>` lifecycle (validate → execute → format)
- Root commands honor `--json`, `--quiet`, `CommandException`, and semantic exit codes
- Example `version` root command in `example/commands/version.dart`
- 4 new integration tests for root commands

## 0.1.0

### Added

- `ModularCli` — entry point that orchestrates modules, global flags, and TTY detection
- `ModuleBuilder` — per-module command registration via `command()`
- `Command<I, O>` — abstract unit of work with `validate()` and `execute()` lifecycle
- `Input` — abstract inbound DTO (deserialize from `CliRequest` flags/params)
- `Output` — abstract outbound DTO with `toJson()` and `exitCode`
- `CommandException` — structured error with `code`, `message`, `details`, `isRetryable`
- `ExitCode` — semantic exit code constants (0, 1, 2, 4, 5, 6, 7, 64)
- `CliOutput` / `JsonCliOutput` / `TextCliOutput` — output formatting abstraction
- `--json` global flag — machine-readable JSON output
- `--quiet` / `-q` global flag — suppress informational messages
- Working example with two modules (greetings + math)
- Full test suite (unit + integration)

