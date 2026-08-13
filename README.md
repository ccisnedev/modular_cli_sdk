[![pub package](https://img.shields.io/pub/v/modular_cli_sdk.svg)](https://pub.dev/packages/modular_cli_sdk)
[![license](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

# modular_cli_sdk

SDK for building modular CLIs with Dart, around two kinds of route:
a **`Query`** reads and answers; a **`Command`** changes something, and says
what it would change before anything runs.

> Also see: [modular_api](https://pub.dev/packages/modular_api) — the HTTP counterpart with the same architecture, and [preview_executor](https://pub.dev/packages/preview_executor) — the engine behind `--plan` / `--apply`.

---

## Quick start

```dart
import 'package:cli_router/cli_router.dart';
import 'package:modular_cli_sdk/modular_cli_sdk.dart';

void main(List<String> args) async {
  final cli = ModularCli();

  // Reads. No --plan, no --apply — it has nothing to plan.
  cli.query<VersionInput, VersionOutput>(
    'version',
    (req) => VersionQuery(VersionInput.fromCliRequest(req)),
    description: 'Print version info',
  );

  cli.module('notes', (m) {
    m.query<ListInput, ListOutput>(
      'list',
      (req) => ListNotes(ListInput.fromCliRequest(req)),
      description: 'List your notes',
      params: ListInput.params,
    );

    // Changes something. --plan / --apply / --autoapprove are declared,
    // enforced and acted on by the SDK; none of it is written here.
    m.command<WriteInput, WriteOutput>(
      'write <name>',
      (req) => WriteNote(WriteInput.fromCliRequest(req)),
      description: 'Write a note',
      params: WriteInput.params,
    );
  });

  final code = await cli.run(args);
  exit(code);
}
```

```bash
dart run bin/main.dart version
# version: 0.2.0

dart run bin/main.dart notes list
# notes: today, ideas

dart run bin/main.dart notes write today
# Error: Choose --plan or --apply.
#   --plan   show what would change; nothing is touched
#   --apply  show it, ask for approval, then do it
# exit code 7

dart run bin/main.dart notes write today --plan
# Plan — notes write
#
#   create   notes
#   create   notes/today.md  (10 characters)
#
# Nothing was changed. Re-run with --apply to carry this out.
```

See [`example/`](example/) for a full working example: three read-only modules and one that writes.

---

## Queries and commands

A CLI has one transport, so nothing about `argv` tells a reader whether a route
is safe to try. `modular_api` gets that distinction from *where* a use case is
published — GraphQL for reads, REST for the rest. Here it is declared, and the
SDK makes the declaration mean something.

|  | `Query` | `Command` |
| --- | --- | --- |
| Contract | `validate()`, `execute()` | `validate()`, `steps()`, `describe()` |
| `--plan` / `--apply` | rejected | declared and enforced |
| Listed under | **Queries:** | **Commands:** |
| `help --json` | `"kind": "query"` | `"kind": "command"` |

They share no method, so neither can be mistaken for the other by accident.

## Commands that say what they would do

A command is an ordered list of steps. Each states its intention through
`preview()` and does its work through `perform()` — two methods, not one method
with a dry-run flag, because a flag threaded through the work leaves nothing
holding the switched-off pass and the real one to the same behaviour.

```dart
class WriteNote implements Step {
  WriteNote(this.path, this.contents);
  final String path;
  final String contents;

  @override
  Preview preview() => File(path).existsSync()
      ? Preview(verb: 'keep', target: path, detail: 'already exists')
      : Preview(verb: 'create', target: path);

  @override
  Future<Outcome> perform(StepContext context) async {
    if (File(path).existsSync()) return Outcome(verb: 'keep', target: path);
    File(path).writeAsStringSync(contents);
    return Outcome(verb: 'create', target: path);
  }
}

class WriteNoteCommand implements Command<WriteInput, WriteOutput> {
  @override
  final WriteInput input;
  WriteNoteCommand(this.input);

  @override
  String? validate() => input.name.isEmpty ? 'a <name> is required' : null;

  @override
  Future<List<Step>> steps() async => [
    EnsureDirectory(input.directory),
    WriteNote(input.path, await render(input)),
  ];

  @override
  WriteOutput describe(Execution execution) =>
      WriteOutput(written: execution.outcomes.map((o) => o.target).toList());
}
```

Under `--apply` the SDK previews the steps, shows the plan, takes the approval,
performs them in order, and compares what each step did against what it had
said. A step that acted differently is reported on stderr whatever the command
chose to say; a step that threw stops the run and fails the invocation.

A command that builds no steps has nothing to approve, so nobody is asked:
`--apply` reports that nothing would change and exits `0`. Asking `y/N` about no
change at all is noise on a terminal, and on a run without one it failed an
invocation that had nothing to fail at.

Note what `describe` does **not** carry: no `planPath`, no `blocked`, no
`message`. Those describe the gate, and the gate is the SDK's.

Two decisions stay with the host:

```dart
ModularCli(
  approver: (plan) => askOnTheTerminal(plan),   // defaults to stdin
  planSink: (plan) => filePlanUnder('.myapp/plans', plan),  // defaults to nowhere
);
```

`--plan` produces a **report**, not an executable plan. Nothing reads it back:
`--apply` re-previews immediately before it acts, so there is no saved plan that
can go stale. See [ADR 0002](docs/adr/0002-a-command-previews-through-a-separate-method.md).

## Testing a command

A command has no `execute()` to call, so `package:modular_cli_sdk/testing.dart`
drives one the way the framework does:

```dart
import 'package:modular_cli_sdk/testing.dart';

final previews = await previewCommand(cmd);   // --plan: nothing is performed
final execution = await runCommand(cmd);      // --apply --autoapprove
final output = await applyCommand(cmd);       // …and the Output it describes
```

`applyCommand` returns the command's own `O`, so a test asserts on its fields
without casting.

Use these rather than writing your own. Your own would be a second description
of the same lifecycle with nothing keeping the two in agreement — so the day
this framework changes, your suite stays green while testing a flow your CLI no
longer takes.

`PreviewExecutor` is exported from here and deliberately **not** from
`modular_cli_sdk.dart`: production code that could reach it could run steps with
no plan shown, no approval taken, and no check that what happened is what was
announced.

> The commands above are **illustrative** — they show how you would run *your*
> CLI, whose entry point is `bin/main.dart`. The runnable equivalents in this
> repository live under `example/`, e.g. `dart run example/example.dart version`.

---

## Running it during development

`dart run` is equivalent to the built binary for a CLI that locates nothing
beside its own executable — the one in the Quick start is such a CLI, and you
can develop it that way all day.

**It stops being equivalent the moment your CLI needs assets.** A modern CLI
usually does: templates, schemas, locale files. During development those assets
have to resolve to your development folder, not to the real installation — and
the way to get that is a **dev build**: the compiled binary placed where the CLI
will actually live, with its assets beside it.

[`example/beside_executable.dart`](example/beside_executable.dart) exists to show
the difference. Built into the layout an installed CLI has — the binary in
`bin/`, `assets/` beside it — it works:

```bash
dart compile exe example/beside_executable.dart -o <root>/bin/beside_executable
mkdir <root>/assets && echo "Hello from the assets folder" > <root>/assets/greeting.txt

<root>/bin/beside_executable greet
# greeting: Hello from the assets folder
```

Run the same code from source and it does not:

```bash
dart run example/beside_executable.dart greet
# Error: no assets/ folder beside this executable: the CLI is running from source [ASSETS_NOT_FOUND]
#   lookedFor: <your-dart-sdk>/assets/greeting.txt
#   resolvedExecutable: <your-dart-sdk>/bin/dart.exe
# exit code 4
```

**Read the `lookedFor` line.** Under `dart run`, `Platform.resolvedExecutable` is
the *Dart* binary, so a CLI resolving paths relative to its own executable
resolves them inside the Dart SDK. Yours will not be there. The two paths are
the only part of that output specific to your machine.

A CLI that does not name this cause reports a broken installation instead, and
sends you to diagnose one that is not broken. That failure has cost real time on
projects built with this SDK, which is why the example is in the repository
rather than in a paragraph.

See [Compile to executable](#compile-to-executable) for the layout.

---

## Help and the command contract

Each command declares its parameters once, on its `Input`. The SDK introspects
its own command registry to render help — the CLI counterpart of the OpenAPI
document `modular_api` generates from its registered use cases.

```dart
class HelloInput extends Input {
  final String name;
  HelloInput({required this.name});

  static final params = [
    CliParam.string('name', abbr: 'n', defaultValue: 'World',
        description: 'Who to greet'),
  ];

  factory HelloInput.fromCliRequest(CliRequest req) =>
      HelloInput(name: req.flagString('name')!); // already resolved and defaulted

  @override
  List<CliParam> get schemaFields => params;

  @override
  Map<String, dynamic> toJson() => {'name': name};
}
```

**Declaring is parsing.** The same declaration that help renders is the one the
framework enforces before your `Input` reads a flag: it resolves `-n` to
`--name`, applies the declared default, coerces `--a abc` to a validation error
instead of a silent `0`, rejects an option nobody declared, and checks
`allowed` values. Help therefore cannot describe a contract the CLI does not
actually apply. A **query** that declares no `params` keeps parsing its
arguments by hand and is neither described nor enforced.

A **command** is always enforced: omitting `params` does not leave it
undeclared, it declares that the command takes nothing but `--plan`, `--apply`
and `--autoapprove`. A route that changes something cannot be the one whose
arguments nobody checks — and the three flags have to be declared to be typed
at all.

Help is a **success**, not an error:

```bash
mycli                      # no args  → command list on stdout, exit 0
mycli help                 #          → same
mycli --help               #  or -h   → same
mycli greetings hello -h   #          → only that command's contract, exit 0
mycli greetings --help     #          → every command in the module, exit 0
mycli help --json          #          → the full contract catalog (help.json), exit 0

mycli bogus                # unknown  → error + catalog on stderr, exit 64
mycli math add --b 7       # rejected → error + that command's usage on stderr, exit 7
```

`help --json` is the machine-readable twin of the text help: every route with
its `kind` (`query` or `command`), description and parameters (name, aliases,
type, required, default, allowed), plus the global options. The `kind` is how an
agent tells a reader from a writer without running either.

A `help` command you register yourself always wins over the built-in one.

---

## Features

- `Query<I, O>` — reads and answers; pure business logic, no I/O concerns
- `Command<I, O>` — changes something, as steps that are held to what they said
- `--plan` / `--apply` / `--autoapprove` — declared, enforced and acted on for every command; neither of the first two is a default
- `Approver` / `PlanSink` — how approval is taken and where a plan is filed, left to the host
- `CliParam` — a route's declared contract: renders help *and* enforces parsing
- Native help — `help`, no args, `--help`/`-h` on stdout with exit 0; `help --json` for machines, with `kind` on every route
- `Input` / `Output` — typed DTOs for I/O
- `CommandException` — structured errors with code, message, exit code, and retryable flag
- `ModularCli` + `ModuleBuilder` — module registration and routing
- Root routes — register without a module prefix via `cli.query()` / `cli.command()`
- `--json` global flag — machine-readable JSON output
- `--quiet` global flag — suppress informational messages
- TTY detection — automatic format selection
- Semantic exit codes — 0 (OK), 1 (error), 4 (not found), 5 (unauthorized), 7 (validation), 64 (usage)
- Built on `cli_router` — GNU flags, middleware, modular mounting

---

## Installation

```bash
dart pub add modular_cli_sdk
```

That resolves the most recent release and writes the constraint for you. This
README deliberately does not print a version to copy into `pubspec.yaml`: a
number written here is one nobody updates, and it was already two releases stale
before anybody noticed.

---

## Error handling

```dart
@override
Future<MyOutput> execute() async {
  final ticket = await repository.findById(input.ticketId);
  if (ticket == null) {
    throw CommandException(
      code: 'TICKET_NOT_FOUND',
      message: 'Ticket #${input.ticketId} not found',
      exitCode: ExitCode.notFound,
    );
  }
  return ShowTicketOutput(ticket: ticket);
}
```

```
Error: Ticket #42 not found [TICKET_NOT_FOUND]
```

With `--json`:
```json
{"error": "TICKET_NOT_FOUND", "message": "Ticket #42 not found", "exitCode": 4, "isRetryable": false}
```

---

## Architecture

```
dart:io / Process           — I/O primitive
       ↓
cli_router                  — routing engine (routes, GNU flags, middleware)
       ↓
modular_cli_sdk             — SDK/framework
       ↓
ModularCli → Module → Query   → Business Logic  → Output → formatted terminal output
                    → Command → Steps → preview → plan   → approval → perform
```

- **Query / Command layer** — pure logic, independent of output format
- **Step layer** — everything a command changes, each piece announced first
- **Output adapter** — turns Output into JSON or plain text based on flags/TTY
- **Middleware** — cross-cutting concerns (logging, auth, metrics)

---

## Documentation

- [API reference](https://pub.dev/documentation/modular_cli_sdk/latest/) — generated dartdoc on pub.dev
- [docs/architecture.md](docs/architecture.md) — the stack, the command lifecycle, the conventions, and the symmetry with modular_api
- [docs/roadmap.md](docs/roadmap.md) — what has shipped, and what is being considered
- [docs/adr/](docs/adr/) — architecture decision records
- [CHANGELOG.md](CHANGELOG.md) — the record of every release

---

## Compile to executable

Compile the binary **into the place the CLI will actually live**, with whatever
it needs beside it:

```
<root>/
  bin/
    my-cli            ← the compiled binary
  assets/             ← whatever the CLI reads at runtime
```

```bash
dart compile exe bin/main.dart -o <root>/bin/my-cli
```

The compiled binary includes the Dart runtime and runs without the SDK installed.

**The `-o` path is not a detail.** A binary compiled into a `build/` directory
with nothing next to it will not find what it expects beside itself — see
[Running it during development](#running-it-during-development). Give it the
same layout it will have once installed, and the dev build answers exactly as
the installed CLI does.

---

## License

MIT © [ccisne.dev](https://ccisne.dev)
