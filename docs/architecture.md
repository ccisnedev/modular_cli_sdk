# Architecture — modular_cli_sdk

## Stack

```
dart:io / Process             — I/O primitive
       ↓
cli_router                    — routing engine (routes, GNU flags, middleware)
       ↓
modular_cli_sdk               — SDK/framework
       ↓
ModularCli                    — entry point
  ├── command('name', factory) — registers a root-level command, no module prefix
  ├── module('name', builder)  — registers commands in a CliRouter sub-tree
  │     └── command()          — wires factory → validate → execute → format
  └── run(args)                — dispatches through cli_router + middleware
```

Root commands and module commands are the same lifecycle; the only difference is
whether a prefix precedes them. Root commands have dispatch priority over
mounted modules, and a root command registered under the empty name owns the
bare invocation.

## Symmetry with modular_api

The two-package split mirrors the HTTP ecosystem:

| Layer | HTTP stack | CLI stack |
|-------|-----------|-----------|
| Transport | `dart:io` / `HttpServer` | `dart:io` / `Process` |
| Router | `shelf` + `shelf_router` | `cli_router` |
| Framework | `modular_api` | `modular_cli_sdk` |
| Entry point | `ModularApi()` | `ModularCli()` |
| Module registration | `api.module('name', builder)` | `cli.module('name', builder)` |
| Root registration | — | `cli.command('name', factory)` |
| Unit of work | `UseCase<I, O>` | `Command<I, O>` |
| Inbound DTO | `Input` (fromJson) | `Input` (fromCliRequest) |
| Outbound DTO | `Output` (statusCode) | `Output` (exitCode) |
| Structured error | `UseCaseException` | `CommandException` |
| Auto docs | OpenAPI + Swagger UI | `help --json` — the contract catalog |

## Command lifecycle

```
args → cli_router dispatch → ModuleBuilder handler
  1. factory(CliRequest) → Command<I, O>
  2. command.validate() → null | error string
  3. command.execute() → Output
  4. CliOutput.writeObject(output.toJson())
  5. return output.exitCode
```

If `validate()` returns an error string, the framework writes a
`CommandException` with `ExitCode.validationFailed` (7) and skips `execute()`.

If `execute()` throws a `CommandException`, the framework catches it,
formats it through the active `CliOutput`, and returns `error.exitCode`.

## The contract

A command declares its parameters once, as `CliParam`s on its `Input`. That one
declaration is both what help renders and what the framework enforces before the
`Input` reads a flag: short aliases resolved, declared defaults applied, values
coerced to their declared type, undeclared options rejected, `allowed` values
checked.

Help therefore cannot describe a contract the CLI does not apply. A command that
declares no `params` keeps parsing its arguments by hand, and is neither
described nor enforced.

## Output formatting

The framework picks the `CliOutput` implementation based on:

1. `--json` flag → `JsonCliOutput`
2. No flag → `TextCliOutput`

Both respect `--quiet` (suppresses `writeMessage()` but not `writeObject()`).

## Exit codes

| Code | Meaning | Typical cause |
|------|---------|---------------|
| 0 | OK | Successful execution |
| 1 | Generic error | Unspecified failure |
| 2 | API error | External service failure |
| 4 | Not found | Requested resource does not exist |
| 5 | Unauthorized | Missing or invalid credentials |
| 6 | Conflict | State machine transition rejected |
| 7 | Validation failed | Input does not satisfy business rules |
| 64 | Invalid usage | Unknown command or bad syntax |

## Conventions

Rules for code written against this SDK. They were carried here from a separate
guide that duplicated the README and drifted from it; they exist nowhere else.

- **One `Command` per use case, one module per domain noun.** A module is a
  domain, not a grab bag.
- **Commands never write to stdout directly — they return data.** The framework
  formats an `Output` through the active `CliOutput`, which is what makes
  `--json` and `--quiet` work at all. A command that prints has opted out of
  both.
- **Use `extends`, not `implements`, for `Input` and `Output` subclasses.**
  Implementing them means reimplementing whatever the base classes later add;
  extending inherits it.
- **Root commands are for standalone operations** — `version`, `init`, `doctor`.
  Anything belonging to a domain belongs in that domain's module.

## Assets, and where a CLI finds them

A compiled Dart CLI resolves `Platform.resolvedExecutable` to itself, so
anything it locates relative to its own executable is found where it was
installed. Run the same code through `dart run` and `resolvedExecutable` is the
Dart binary instead: the CLI looks inside the Dart SDK and finds nothing.

This SDK provides no asset resolution — a CLI that needs assets writes its own.
What it does provide is a worked example of the failure and how to avoid it:
[`example/beside_executable.dart`](../example/beside_executable.dart), and the
README section that runs it both ways.
