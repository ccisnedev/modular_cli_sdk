# Architecture — modular_cli_sdk

## Stack

```
dart:io / Process             — I/O primitive
       ↓
cli_router                    — routing engine (routes, GNU flags, middleware)
       ↓
preview_executor              — steps, their previews, and the run that checks them
       ↓
modular_cli_sdk               — SDK/framework
       ↓
ModularCli                    — entry point
  ├── query('name', factory)   — a root-level route that reads
  ├── command('name', factory) — a root-level route that changes something
  ├── module('name', builder)  — registers routes in a CliRouter sub-tree
  │     ├── query()            — factory → validate → execute → format
  │     └── command()          — factory → validate → flags → steps → preview
  │                              → plan | approval → perform → describe
  └── run(args)                — dispatches through cli_router + middleware
```

Root routes and module routes are the same lifecycle; the only difference is
whether a prefix precedes them. Root routes have dispatch priority over mounted
modules, and one registered under the empty name owns the bare invocation.

`preview_executor` sits below the SDK rather than inside it because the problem
it solves is not a CLI's. `modular_api` has the same one from the other end of
the wire — an endpoint that wants a dry-run needs exactly this — so the engine
is a package both can depend on, and neither owns.

## Symmetry with modular_api

The two-package split mirrors the HTTP ecosystem:

| Layer | HTTP stack | CLI stack |
|-------|-----------|-----------|
| Transport | `dart:io` / `HttpServer` | `dart:io` / `Process` |
| Router | `shelf` + `shelf_router` | `cli_router` |
| Framework | `modular_api` | `modular_cli_sdk` |
| Entry point | `ModularApi()` | `ModularCli()` |
| Module registration | `api.module('name', builder)` | `cli.module('name', builder)` |
| Root registration | — | `cli.query('name', f)` / `cli.command('name', f)` |
| Reading unit | `UseCase<I, O>` published over GraphQL | `Query<I, O>` |
| Writing unit | `UseCase<I, O>` published over REST | `Command<I, O>` |
| Inbound DTO | `Input` (fromJson) | `Input` (fromCliRequest) |
| Outbound DTO | `Output` (statusCode) | `Output` (exitCode) |
| Structured error | `UseCaseException` | `CommandException` |
| Auto docs | OpenAPI + Swagger UI | `help --json` — the contract catalog |

The reading/writing split is the one thing the two stacks arrive at differently.
`modular_api` gets it from the transport: publishing a use case over GraphQL is
what makes it a read. A CLI has one transport, so it has to be declared — which
is why the SDK has two contracts where `modular_api` has one.

## Query lifecycle

```
args → cli_router dispatch → ModuleBuilder handler
  1. factory(CliRequest) → Query<I, O>
  2. query.validate() → null | error string
  3. query.execute() → Output
  4. CliOutput.writeObject(output.toJson())
  5. return output.exitCode
```

## Command lifecycle

```
args → cli_router dispatch → ModuleBuilder handler
  1. factory(CliRequest) → Command<I, O>
  2. command.validate() → null | error string
  3. ChangeFlags.validate() → exactly one of --plan / --apply
  4. command.steps() → List<Step>
  5. every step previewed → PlanDocument
     --plan   → PlanSink files it, PlanOutput written, stop here
     --apply  → Approver is asked, unless --autoapprove
  6. PreviewExecutor.perform(steps) → Execution
     each step re-previewed immediately before it runs, and the two compared
  7. command.describe(execution) → Output
  8. discrepancies and failures written to stderr, whatever the command reported
```

If `validate()` returns an error string, the framework writes a
`CommandException` with `ExitCode.validationFailed` (7) and does nothing else —
including building the steps, so a command that would read a disk or reach a
network does neither.

If anything throws a `CommandException`, the framework catches it, formats it
through the active `CliOutput`, and returns `error.exitCode`.

A run that stopped halfway (a step threw) fails the invocation even when the
command found something to report about the part that ran. A run that reached
its end having done something it had not announced keeps the command's exit
code, and the discrepancy is written to stderr regardless: the broken promise
was the framework's, and a reader must not have to take the command's word
for it.

## The contract

A command declares its parameters once, as `CliParam`s on its `Input`. That one
declaration is both what help renders and what the framework enforces before the
`Input` reads a flag: short aliases resolved, declared defaults applied, values
coerced to their declared type, undeclared options rejected, `allowed` values
checked.

Help therefore cannot describe a contract the CLI does not apply. A **query**
that declares no `params` keeps parsing its arguments by hand, and is neither
described nor enforced.

A **command** is always enforced. Omitting `params` does not leave it
undeclared: it declares that the command takes nothing but `--plan`, `--apply`
and `--autoapprove`. A route that changes something cannot be the one whose
arguments nobody checks, and the three flags have to be declared to be typed.

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

- **One `Query` or `Command` per use case, one module per domain noun.** A
  module is a domain, not a grab bag.
- **A route that changes anything is a `Command`.** Registering a writer as a
  query is how a CLI ends up with a change nobody can preview, and nothing but
  this rule prevents it.
- **Everything a command changes belongs inside a `Step`.** Work done in
  `steps()` or `describe()` is work that was never announced, and the executor
  cannot hold it to anything.
- **A step settles what it needs in its constructor.** Deriving the same answer
  in `preview()` and again in `perform()` is how the two come to describe
  different changes — the failure the whole arrangement exists to prevent.
- **Queries and commands never write to stdout directly — they return data.**
  The framework formats an `Output` through the active `CliOutput`, which is
  what makes `--json` and `--quiet` work at all. A unit that prints has opted
  out of both.
- **Use `extends`, not `implements`, for `Input` and `Output` subclasses.**
  Implementing them means reimplementing whatever the base classes later add;
  extending inherits it.
- **Root routes are for standalone operations** — `version`, `init`, `doctor`.
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
