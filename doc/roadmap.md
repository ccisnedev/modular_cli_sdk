# Roadmap — modular_cli_sdk

> Current version: **0.1.0** (published 2026-03-27).
> Source of truth for planned features. Updated as versions ship.

---

## v0.1.0 — Released

Core framework. Everything needed to build modular CLIs with typed commands.

- `ModularCli` + `ModuleBuilder` — module registration and routing
- `Command<I, O>` — abstract unit of work with `validate()` / `execute()` lifecycle
- `Input` / `Output` — typed DTOs for command I/O
- `CommandException` — structured errors with code, message, exit code, retryable flag
- `ExitCode` — semantic exit code catalog (0, 1, 2, 4, 5, 6, 7, 64)
- `CliOutput` / `JsonCliOutput` / `TextCliOutput` — output formatting
- `--json` global flag — machine-readable output
- `--quiet` / `-q` global flag — suppress informational messages
- TTY detection — automatic format selection

---

## v0.2.0 — Declarative flags + schema export

Make commands self-describing for tooling, completions, and documentation.

- `Flag` class — declarative flag registration with type, default, aliases, help text
- Automatic flag validation (required, type mismatch, enum values)
- Per-command `--help` — generated from flag metadata
- `schema --json` — export full command tree + flag metadata as JSON
- Shell completions — bash, zsh, fish, PowerShell (generated from command tree)

---

## v0.3.0 — Config and context

Layered configuration with precedence: flag > env > project > user > default.

- `CliConfig` — layered config resolution
- Persistent context (`cli context set key value`)
- Config commands (`cli config set/get/list`)
- Profile support (`~/.config/<app>/profiles/`)

---

## v0.4.0 — Extended output formats

More output modes for different consumption patterns.

- `--format` flag (table / json / csv / tsv / value)
- `--jq` inline filtering
- Table formatting with column alignment and ANSI colors
- TSV fallback when piping (no TTY)

---

## v0.5.0 — Interactivity

Interactive prompts when running in a terminal.

- Prompt for missing required args when TTY detected
- `--yes` / `-y` — skip confirmation prompts
- `--non-interactive` — disable all prompts (for CI/CD)

---

## Future

- Command aliases (`cli alias set bugs 'ticket list --state open'`)
- Plugin system for third-party command modules
- Telemetry hooks (opt-in usage metrics)
