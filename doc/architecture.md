# Architecture — modular_cli_sdk v0.1.0

> Published on [pub.dev](https://pub.dev/packages/modular_cli_sdk).
> See also: [API reference](https://pub.dev/documentation/modular_cli_sdk/latest/), [roadmap](roadmap.md).

## Stack

```
dart:io / Process             — I/O primitive
       ↓
cli_router                    — routing engine (routes, GNU flags, middleware)
       ↓
modular_cli_sdk               — SDK/framework
       ↓
ModularCli                    — entry point
  ├── module('name', builder) — registers commands in a CliRouter sub-tree
  │     └── command()         — wires factory → validate → execute → format
  └── run(args)               — dispatches through cli_router + middleware
```

## Symmetry with modular_api

The two-package split mirrors the HTTP ecosystem:

| Layer | HTTP stack | CLI stack |
|-------|-----------|-----------|
| Transport | `dart:io` / `HttpServer` | `dart:io` / `Process` |
| Router | `shelf` + `shelf_router` | `cli_router` |
| Framework | `modular_api` | `modular_cli_sdk` |
| Entry point | `ModularApi()` | `ModularCli()` |
| Module registration | `api.module('name', builder)` | `cli.module('name', builder)` |
| Unit of work | `UseCase<I, O>` | `Command<I, O>` |
| Inbound DTO | `Input` (fromJson) | `Input` (fromCliRequest) |
| Outbound DTO | `Output` (statusCode) | `Output` (exitCode) |
| Structured error | `UseCaseException` | `CommandException` |
| Auto docs | OpenAPI + Swagger UI | JSON schema export (v0.2.0+) |

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

## What's next

See the [roadmap](roadmap.md) for planned features (declarative flags, schema export, shell completions, config persistence).
