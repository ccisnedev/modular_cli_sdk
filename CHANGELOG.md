# Changelog
All notable changes to this project will be documented in this file.

The format loosely follows [Keep a Changelog](https://keepachangelog.com/)
and the project adheres to [Semantic Versioning](https://semver.org/).

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

