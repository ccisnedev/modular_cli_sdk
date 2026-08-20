# Changelog
All notable changes to this project will be documented in this file.

The format loosely follows [Keep a Changelog](https://keepachangelog.com/)
and the project adheres to [Semantic Versioning](https://semver.org/).

## 0.5.0

> Prepared as two releases and shipped as one. The version here was raised to
> 0.5.0 once and the release never went out, so the last version on pub.dev is
> **0.4.1** and everything below is what changed since it. The first half of
> this entry was written as 0.5.1 before that was noticed; there is no 0.5.1,
> and never was.

### Added

- **`ExplainsNothingToDo` — a command can say why its plan is empty.** The
  change further down — no longer calling `describe` for an empty plan — was
  right, and it made a gap visible that had been there all along: the framework can report *that*
  nothing would change, and only the command knows *why*.

  The two CLIs built on this SDK had four such messages between them —
  `Already on the latest version`, `Latest release is a prerelease —
  skipping.`, `No AI coding host found on this machine — nothing deployed.
  Supported: … Pass --host <host> to install into one anyway.` and `No
  supported assistant found in your home directory.` Each states what a caller
  can act on. `nothing would change` states a fact and withholds it.

  ```dart
  class UpgradeCommand
      implements Command<UpgradeInput, UpgradeOutput>, ExplainsNothingToDo {
    @override
    String? get nothingToDo => _reason;  // set while building steps
  }
  ```

  Read once, immediately after `steps()` — which is where a command works this
  out. It reaches `--plan` and `--apply` alike, because both render the same
  `PlanDocument`, and `--json` carries it as `nothingToDo` on the plan and as
  `reason` on the answer.

  **Opt-in, and deliberately not a member of `Command`.** Most commands cannot
  produce an empty plan, and adding a member to an interface every host
  `implements` would have broken all 23 existing commands and taxed every future
  one with `=> null`. Both hosts were checked against this release without a
  single change: `dart analyze --fatal-infos` clean on each.

### Fixed

- **`--plan` no longer tells you to re-run an `--apply` that would do nothing.**
  An empty plan ended with `Re-run with --apply to carry this out`, which invites
  a second identical run to go and find the same nothing. It now says
  `Nothing to carry out, so --apply would do nothing either.` A plan with steps
  is unchanged.

- **An empty plan was mute under `--plan` too**, and always had been — that path
  never called `describe`, so on that side the silence long predates the change
  below. Both paths now show the command's reason when it gives one.

### Fixed — the empty plan

- **`--apply` no longer asks about a plan that changes nothing.** A command
  whose `steps()` came out empty still went through the approver, so a person
  was shown `nothing would change` and then asked `Apply this plan? [y/N]`
  about it. Worse where there was no terminal to answer: `--apply` refused with
  `NoApproverAvailable` and exited non-zero, failing an invocation that had
  nothing to do.

  An empty plan is now reported and the run ends `0` — the caller asked for a
  state and the state is already the one asked for. The answer is the new
  framework-produced `NothingToDoOutput`, alongside `PlanOutput` and
  `DeclinedOutput`; under `--json` it carries the plan plus
  `"applied": false, "reason": "nothing would change"`.

  This also short-circuits `--apply --autoapprove`, so both invocations answer
  the same way.

### Changed — BREAKING

- **Narrowly, but really.** A command that builds no steps no longer has
  `describe` called with an empty `Execution`. That path used to work under
  `--apply --autoapprove`, so a host could be relying on it — and the exit code
  it returned is now `0` whatever that `Output` said. A command that reported
  "already up to date" through `describe`, or that failed the run from an empty
  execution, will find the SDK answering for it instead.

  Hence 0.5.0 rather than 0.4.2: the surface only grew, but the behaviour of a
  reachable path changed, and an exit code that silently turns into `0` is
  exactly the kind of change a caller deserves to be told about by the version
  number. A host that implements `ExplainsNothingToDo` gets a better answer
  back than the one it lost — see above.

## 0.4.1

### Added

- **`package:modular_cli_sdk/testing.dart`** — `previewCommand`, `runCommand`
  and `applyCommand`, which drive one `Command` exactly as `ModuleBuilder`
  does. A carence found the first time a real CLI was migrated: a command has
  no `execute()` to call any more, so a test that holds one command has to
  build its steps and run them — which is what the framework does, and what
  every host would otherwise hand-roll.

  Hand-rolling it is the hazard. A host's own copy is a second description of
  the same lifecycle with nothing keeping the two in agreement, so the day the
  framework changes, that suite stays green while testing a flow the CLI no
  longer takes. That is the dry-run flag again, in the test suite. Two of the
  library's own tests pin the agreement: `applyCommand` produces what
  `--apply --autoapprove` produces, and `previewCommand` produces what `--plan`
  lists.

  `applyCommand` returns the command's own `O`, not `Output`, so a test asserts
  on its fields without casting.

### Notes

- **`PreviewExecutor` is still not exported from `modular_cli_sdk.dart`**, and
  now the library says why. The engine publishes it because the engine's
  consumer is a framework; this library's consumer is a command author, for
  whom the same class is a way to run steps with no plan shown, no approval
  taken and no check that what happened is what was announced. Narrowing the
  surface for a different audience is what the re-export is for. `testing.dart`
  exports it, because a test standing in for the framework legitimately needs it

## 0.4.0

A CLI built on this SDK could not say which of its routes change things, and had
no way to show what a change would do before doing it. Both are now the SDK's
job. See [ADR 0002](docs/adr/0002-a-command-previews-through-a-separate-method.md).

### Added

- **`Query<I, O>`** — a route that reads and answers. `validate()` and
  `execute()`, which is exactly what `Command` was until now
- **`Command<I, O>`** — a route that changes something, as an ordered list of
  steps: `validate()`, `steps()` and `describe(Execution)`. A step states its
  intention through `preview()` and does its work through `perform()`, and the
  executor compares the two. The preview is therefore checked rather than
  trusted, which a dry-run flag threaded through the work can never be
- **`m.query(...)` / `m.command(...)`**, and the same pair on `ModularCli` for
  root routes. Which one a route is registered as decides what the framework
  does with it, so "this changes something" is a fact about the registration
  rather than a comment in the file
- **`--plan`, `--apply` and `--autoapprove`**, declared on every command and
  rejected on every query. Neither of the first two is a default: a bare
  invocation of a command is an error. `--autoapprove` on its own authorizes
  nothing and says so
- **`Approver`** — how an approval is taken, injected on `ModularCli`. The
  default asks on the terminal and **refuses rather than hangs** when there is
  no terminal to ask, naming `--autoapprove` as the way through
- **`PlanSink`** — where a plan is filed, injected on `ModularCli`. Defaults to
  nowhere: whether a project keeps plans on disk is that project's decision
- **`PlanOutput` / `DeclinedOutput`** — the framework's own answers for "nothing
  happened yet" and "you said no", so that no command has to model either
- **`CommandKind`** on every catalog entry, published by `help --json` as
  `"kind"`. Text help lists queries apart from commands when a CLI has both, and
  keeps one list when it does not
- **`example/modules/notes/`** — the example's first writing route, exercised by
  the suite through both `--plan` and `--apply`

### Changed

- **BREAKING — `Command` no longer has `execute()`.** Every existing command is
  what is now a `Query`: change `implements Command<I, O>` to
  `implements Query<I, O>` and `m.command(...)` to `m.query(...)`. Nothing else
  about a reading route changes
- **BREAKING — a command is always enforced.** Omitting `params` no longer
  leaves it undeclared; it declares that the command takes nothing but the three
  flags. Queries keep the old behaviour
- **`HelpCommand` is now `HelpQuery`**, because help changes nothing — which is
  also why `help --plan` is rejected without that having to be arranged
- **A step that acted differently from its own preview is reported on stderr**
  whatever the command chose to say, and does not stop the run: it did do
  something, and later steps may depend on it. A step that *throws* stops the
  run and fails the invocation even when the command reported what it managed

### Notes

- **The engine is [`preview_executor`](https://pub.dev/packages/preview_executor)**,
  a separate package that knows nothing about CLIs. `modular_api` has the same
  problem from the other end of the wire, so the engine belongs to neither.
  `Step`, `Preview`, `Outcome` and `Execution` are re-exported here, so a
  command author still imports one package
- **`--plan` writes a report, not an executable plan.** `--apply` never reads it
  and re-previews immediately before acting, so there is no saved plan that can
  go stale, and none of Terraform's staleness machinery is needed

## 0.3.5

### Fixed

- **The documentation no longer teaches a way of running that answers wrongly.** A compiled Dart CLI resolves `Platform.resolvedExecutable` to itself, so whatever it locates beside its own executable is found where it was installed. Run the same code through `dart run` and that path is the *Dart* binary: the CLI looks inside the Dart SDK, finds nothing, and reports a broken installation that is not broken. Nothing here said so, and `## Compile to executable` sent the binary to `build/` with nothing next to it — a layout in which the failure is guaranteed. It now teaches the layout an installed CLI has, the binary in `bin/` with `assets/` beside it

  The Quick start is deliberately unchanged. `dart run` is genuinely equivalent for a CLI that locates nothing beside itself, and forbidding it would be stricter than the truth. The limit is taught by demonstration instead

- **The roadmap said things that were not true.** It announced v0.2.0 and v0.3.0 as planned with the package already at 0.3.4, and promised a `Flag` class where `CliParam` was built, plus `CliConfig`, profiles and `cli context set` — none of which exist. It now names what shipped, and what is merely being considered carries no version number, because attaching one to something unbuilt is how it went wrong

- **The architecture document never mentioned root commands**, which shipped in 0.2.0 and which the README lists as a feature

### Added

- **`example/beside_executable.dart`** — a CLI that reads an asset from beside its own executable, so the failure above is reproducible in this repository rather than described in it. Built into `bin/` with `assets/` alongside, it answers; run from source it names the cause instead of blaming the installation
- **`test/running_from_source_test.dart`** — pins three facts: the Quick start's CLI answers the same either way, the second example answers differently, and the outputs printed in the README are the ones the commands produce. It compiles executables and is slower than the rest of the suite together
- **Continuous integration**, which this repository had never had — `ubuntu-latest` and `windows-latest`, mirroring `macss`. Nothing here had previously been demonstrated outside Windows

### Removed

- **`AGENTS.md`.** It restated the README in its own words and drifted from it. The three conventions that lived only there were carried into `docs/architecture.md` first
- **`doc/`** as a home for hand-written documentation. It is git-ignored and left to what `dart doc` generates, which the Dart package layout convention says does not belong under source control. Everything written by hand is in **`docs/`**, which is now versioned — it never had a file tracked in it before
- The pinned `modular_cli_sdk: ^0.3.0` snippet from `## Installation`, which was two releases stale, and a duplicated `dart pub add` line beside it

### Notes

- **No public API changed.** `git diff` over `lib/` for this release is empty; this is documentation, examples, tests and CI. That is why it is a PATCH

## 0.3.4

### Fixed

- **An incomplete invocation is no longer reported as an unknown command.** Typing the beginning of a registered route without reaching its end — `math` where `math add` exists — answered `unknown command 'math'` followed by the whole catalog. The name was real; what was missing was the end of it, and the user was sent looking for a typo they had not made. The error path now asks the catalog whether what was typed *continues* into any route, says so, and lists only those continuations

  The rule is stated over routes rather than modules on purpose. `api graphql` is not a module — it is the first segment of the route `api graphql compile` — so a module-only check would have left it reported as unknown. Prefix-of-a-route covers the module without an action and the half-typed route as the one case they are, and is the simpler rule of the two

  A name that begins no registered route keeps exactly the behaviour it had: it is named, and the full catalog follows. The exit code is unchanged for both, and is now pinned by a test rather than inherited

  No public API was added. The completions are rendered by narrowing what `HelpRenderer` is given rather than teaching it a new shape, which keeps it the only place help text is produced

### Notes

- This does **not** give the surface position help of its own. `api graphql --help` still renders nothing; what changes is that the error stops calling it unknown. Whether a CLI should have three levels at all is a question for the CLIs built on this SDK, not for the SDK

## 0.3.3

### Fixed

- **A command with positionals can be asked for its contract.** The router cannot match `show <id>` until the id is supplied, so `show --help` fell to the error path — the user had to provide the very argument he was asking about. A command is now *named* by its route without positional placeholders, so both `show --help` and `help show` render its contract. `show 1 --help` keeps working

### Added

- `CommandContract.name` — the route without its positional placeholders, i.e. the tokens a user types to name the command
- `CommandCatalog.forName` — lookup by that name

## 0.3.2

### Fixed

- **A command can now declare that it accepts no options, and be enforced.** `params` defaulted to `const []`, so declaring an empty contract was the same value as declaring none: a zero-argument command was indistinguishable from an undeclared one and its arguments went unchecked — `init --host foo` ran, silently doing nothing the flag implied. `params` is now nullable (`null` = declares nothing, unenforced, as before; `[]` = declares no options, and any option is rejected)

### Changed

- `ModularCli.command` / `ModuleBuilder.command` take `List<CliParam>? params` (was `List<CliParam> params = const []`). Source-compatible: omitting `params` behaves exactly as before
- `CommandContract.params` is `List<CliParam>?`, with `isDeclared` and `declaredParams` for the two readings

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

