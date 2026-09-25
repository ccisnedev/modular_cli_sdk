# Changelog
All notable changes to this project will be documented in this file.

The format loosely follows [Keep a Changelog](https://keepachangelog.com/)
and the project adheres to [Semantic Versioning](https://semver.org/).

## 0.6.0

Built against `cli_router: { path: ../cli_router-0.2.0 }`. The constraint
must become `cli_router: ^0.2.0` once that release is published to pub.dev.
This entry is written against the API `cli_router` 0.2.0 carries as of commit
`0f28e32`: `abbr` is required on every `OptionSpec`, `mount()` requires equal
`globalOptions` on both routers, and a bare `--` after an operand is
rejected. No bug or missing API was found in it while building this one.

### Added

- **`CliPositional`**: a declared positional argument (`.string`, `.integer`,
  `.number`), distinct from `CliParam` because it has no `--name`, no
  abbreviation and no repeatability. Renders in help and is enforced exactly
  like an option. `required` is a mandatory, no-default `bool`: a route
  pattern's trailing `[<name>]` segment is declared with `required: false`,
  and registration cross-checks the contract's positionals against the
  pattern's: a missing, extra, misnamed, duplicated, or wrongly-required/
  optional positional declaration is an `ArgumentError` at registration time,
  not a silent pass-through at dispatch
- **`ModularCli.shortcut(pattern, {target, globals, contract, description})`**:
  a declared route that runs another route's handler under a narrower
  contract (issue #27 section 4), dispatched through the shortcut's *own*
  contract, never the target's. `target` names the route it dispatches to by
  its router pattern (e.g. `'eval rpn'`) and must match exactly one
  registered route; registration fails with an `ArgumentError` if `target` is
  not registered, or if it is ambiguous (matches more than one route). A
  shortcut never declares its own positionals: they are derived from
  `target`'s own declaration, by name, and rebound to whichever cardinality
  `pattern` itself gives them — declaring one directly in `contract` is an
  `ArgumentError`. `contract` is optional and defaults to `CliContract.none`,
  so issue #27's own example, `shortcut('<program>', target: 'eval rpn',
  globals: false)`, works with no `contract:` argument at all. Like every
  other registration call, `globals` has no default: a shortcut states
  explicitly whether the SDK's global options (`--plan`, `--apply`, `--json`,
  and so on) are accepted on it
- **`CommandCatalog.suggest(word, {maxDistance = 2})`** (issue #27 section 6):
  the closest word in the catalog's route vocabulary to `word`, by
  restricted edit distance (Levenshtein plus one adjacent-transposition
  operation, i.e. Damerau-Levenshtein limited to non-overlapping
  transpositions), `<= maxDistance`; ties are broken by catalog registration
  order; returns `null` when nothing is within range. Wired into
  `unknownCommand` and `incomplete` rejections, so `commands shwo power`
  suggests `show`
- **`CliContract`**: the full declared shape of a route's arguments:
  `options` (`CliParam`), `positionals` (`CliPositional`) and `constraints`
  (`CliConstraint`), replacing the bare `List<CliParam>? params`.
  `CliContract.none` declares nothing; `withOptions()` returns a copy with
  extra options appended (how the SDK adds `--plan`/`--apply`/`--autoapprove`
  to a command's own contract without mutating it)
- **`CliConstraint`, `ExactlyOne`, `MutuallyExclusive`**: cross-field rules
  checked once every option has been read and defaulted, over the set of
  option names actually *present* on the invocation (a `DeclaredDefault` does
  not count as present)
- **`DeclaredDefault<T>`**: a default value wrapped with a required `reason`,
  so a default is never silent; help renders `default: <value>` from it
- **`--help` wins over enforcement.** `<command> --help` on an otherwise
  invalid or incomplete invocation now always renders that command's contract
  and exits `0`, instead of failing enforcement first. Concretely: an
  invocation the router classifies as `incomplete`, `missingArgument` or
  `missingRequiredOption` is help-eligible; `--help` short-circuits it
- **A half-typed route says so specifically.** `math` (where only `math add`
  is registered), `api graphql` (a route prefix, not a module) and a route hit
  with an unrelated bad option before its own contract could be resolved are
  now all reported as `'<what you typed>' is not a complete command`, instead
  of the router's generic `incomplete command` / `does not continue this
  command` wording, whenever no contract names the exact invocation but at
  least one registered route continues it
- **Exit codes `dataError` (65, `EX_DATAERR`) and `configError` (78,
  `EX_CONFIG`)**, alongside the existing eight (`ExitCode.all` now has 10
  entries)
- `test/cli_positional_test.dart`, `test/cli_contract_test.dart`: dedicated
  coverage for the two new declaration types

### Changed (BREAKING)

- **`params: List<CliParam>?` is gone; every route declares `contract:
  CliContract` instead.** `command(...)` / `query(...)` on both `ModularCli`
  and `ModuleBuilder` take `contract` (defaulting to `CliContract.none`), not
  `params`. A positional argument, previously undeclarable, is now a
  `CliPositional` inside the same contract a route's options live in
- **`Input.schemaFields` and `Output.schemaFields` are removed.** They were
  reserved surface that predated `CliContract`; a route's `Input` now exposes
  its contract as a `static final contract`, read by the registration call,
  not by an interface member every `Input`/`Output` had to carry
- **A positional can be optional.** A route pattern's trailing `[<name>]`
  segment is declared with a `CliPositional(required: false)`; help renders
  `Usage: eval rpn [options] [<program>]`, with the bracket and the
  "required"/"optional" facet both taken from the pattern and the
  declaration, not hand-rolled
- **Every error, under `--json`, is now one shape, nested under `"error"`.**
  Previously a router-level rejection (unknown command, missing required
  option, …) surfaced as `{"error": "<raw human-readable message>", "kind":
  ..., "contract": ...}`, a different shape from `CommandException.toJson()`,
  and carried a `kind` field and an `isRetryable` flag. Both are now:
  `{"error": {"id": "<kebab-case-id>", "message": "<text>", "exitCode":
  <int>, "contract": ..., "details": {...}}}` — `contract` and `details` are
  only present when they apply, and there is no `kind` and no `isRetryable`.
  A router rejection's `id` comes from a fixed table (documented in
  README.md's "Error handling" section): `unknown-command`,
  `incomplete-command`, `missing-argument`, `extra-argument`,
  `unknown-option`, `misplaced-option`, `missing-required-option`,
  `repeated-option`, `invalid-short-option`, `missing-value`,
  `unexpected-value`. An SDK-enforced contract violation (a required option
  missing, the wrong type, an allow-list mismatch, a failed `CliConstraint`)
  raises a `CommandException` with `id: 'validation-failed'`, a twelfth id
  not in that table, since it is not a router rejection. A `--json` caller
  now has one error vocabulary and one place to look for it, regardless of
  whether the rejection came from `cli_router`, the SDK's own enforcement, or
  a handler's own `CommandException`
- **`CommandException.code` is renamed to `id`, and validated.** `id` is
  `required`, kebab-case (`^[a-z0-9]+(-[a-z0-9]+)*$`), and throws
  `ArgumentError` at construction otherwise; `exitCode` is now `required`
  with no default. `details` (`Map<String, dynamic>?`, optional, free-form)
  replaces the old fixed field set, so a domain error — for example
  calculatrix's — can carry `token`/`position` through it. `isRetryable` is
  removed entirely; nothing in either CLI built on this SDK read it
- **`help --json`'s `route` and `kind` keys**: `kind` is the route's
  `CommandKind` (`"query"` / `"command"`); a JSON consumer keying off the
  wrong field will find one missing rather than silently reading the other's
  value
- **The generated `Usage:` line orders options before positionals**:
  `Usage: notes write [options] <name>`, not `<name> [options]`, because
  `cli_router`'s grammar requires every option to precede the first
  positional on the actual command line (an option can never follow an
  operand); the old order documented an invocation the router would reject
- **`CliParam`'s `abbr` and `defaultValue` are required on every factory
  (`.string`, `.integer`, `.number`, `.flag`, `.enumeration`), but stay
  nullable.** Previously both were optional parameters that silently
  defaulted to `null`/absent, so a call site could not tell "no abbreviation,
  on purpose" from "I forgot the abbreviation." Every call site now writes
  `abbr: null` or `defaultValue: null` explicitly when it means that
- **`contract` is required, with no default, on `query()` and `command()`**
  (`ModularCli` and `ModuleBuilder` alike). `CliContract.none` remains
  available and is one explicit keystroke away; what is gone is a route
  silently getting an empty contract because `contract:` was left off
- **`ModularCli(...)` requires `suggestionDistance`, with no default.** The
  "did you mean" suggestion introduced in this release (`CommandCatalog.
  suggest`) needs a distance threshold from somewhere; leaving it defaulted
  would mean most call sites never think about it. Every construction now
  passes one explicitly (this SDK's own example and tests use `2`)

### Fixed

- **A constraint (`ExactlyOne`, `MutuallyExclusive`) now counts a bound
  positional by name, the same as an option.** Previously only option
  presence was checked, so `eval rpn '1 2 +'` (the positional alone) ran
  unconstrained while `eval rpn --stdin '1 2 +'` was correctly rejected by
  `ExactlyOne(['program', 'file', 'stdin'])`; both are rejected now, and
  supplying both a flag and the positional is caught as the two-members-
  present violation it always was
- **Every occurrence of a repeatable option is validated**, not just the
  first (`repeat --count 1 --count bad` is now a validation failure instead
  of silently accepting the first value and ignoring the rest)
- **A `DeclaredDefault` is checked against its own declaration.** An
  enumeration's default that is not one of its `values` is an
  `ArgumentError` at registration time; a `mustExist`-constrained path's
  default is validated before dispatch exactly like a value the caller
  supplied, instead of bypassing the filesystem check because nothing was
  typed
- **A route is identified consistently by the router's `CliRoute`** (its
  pattern and literal words) everywhere the SDK looks one up. Previously the
  catalog derived a route's identity from its own contract-formatted string
  (`eval rpn [<program>]` → name `eval rpn []`), which diverged from what the
  router reports (`eval rpn`) and broke `help eval rpn`, the module-help
  fallback shown for `eval rpn --help` alongside a missing required option,
  and the `contract`/`details` fields of a JSON error for any route with a
  positional segment
- **The "is not a complete command" rewrite only applies to an actual
  `incomplete` rejection.** `eval --json --bogus` previously kept the kind
  `unknownOption` but relabelled the message as "'eval' is not a complete
  command"; every rejection kind other than `incomplete` now keeps the
  router's own message, even when it occurs under a prefix that is itself
  incomplete
- **`cli.module('', (m) { ... })` no longer throws.** Mounting a prefix
  requires exactly one literal word in `cli_router`'s grammar, so an
  empty-name module's routes are registered directly on the root router
  instead of being mounted
- **The catalog's handler map is keyed by route, not by bare name.** Two
  routes that share a leading word but differ in arity — `show` and `show
  <id>` — previously collided in a name-keyed map, so registering both left
  only one dispatchable; each is now keyed by its own `CliRoute` and both
  dispatch correctly
- **`repeat --count bad --help` is now a validation failure, not a help
  screen.** `--help` short-circuiting enforcement (see above) was only meant
  to apply when the invocation is *incomplete*, not when a supplied value is
  outright invalid; `--count bad` is a validation failure regardless of
  `--help`, so it no longer exits `0`
- **`globals: false` on a route now omits the SDK's global options
  (`--plan`, `--apply`, `--json`, `--autoapprove`, …) from that route's own
  focused help**, not just from enforcement. Previously a route that
  declined the global options still had them listed in `<command> --help`,
  which documented flags the route would then reject
- **A wildcard positional's usage line renders its own `*`.** `batch *`'s
  generated `Usage:` line previously dropped the trailing `*`, documenting
  an invocation (`batch`, no arguments) that the route does not actually
  accept

### Notes

- `dart analyze` is clean except for the expected `invalid_dependency`
  warning on the intentional local path dependency on `cli_router`
- Every invocation in this README, the example app and the test suite that
  exercises a route with a positional now places its options before the
  positional, per the grammar rule above

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

