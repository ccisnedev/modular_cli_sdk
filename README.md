[![pub package](https://img.shields.io/pub/v/modular_cli_sdk.svg)](https://pub.dev/packages/modular_cli_sdk)
[![license](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

# modular_cli_sdk

Command-centric SDK for building modular CLIs with Dart.
Define `Command` classes (input → validate → execute → output), connect them to CLI routes, and get automatic output formatting with JSON and plain text modes.

> Also see: [modular_api](https://pub.dev/packages/modular_api) — the HTTP counterpart with the same architecture.

---

## Quick start

```dart
import 'package:cli_router/cli_router.dart';
import 'package:modular_cli_sdk/modular_cli_sdk.dart';

void main(List<String> args) async {
  final cli = ModularCli();

  // Root-level commands (no module prefix)
  cli.command<VersionInput, VersionOutput>(
    'version',
    (req) => VersionCommand(VersionInput.fromCliRequest(req)),
    description: 'Print version info',
  );

  // Module-scoped commands, declaring their contract
  cli.module('greetings', (m) {
    m.command<HelloInput, HelloOutput>(
      'hello',
      (req) => HelloCommand(HelloInput.fromCliRequest(req)),
      description: 'Say hello to someone',
      params: HelloInput.params,
    );
  });

  final code = await cli.run(args);
  exit(code);
}
```

```bash
dart run bin/main.dart version
# version: 0.2.0

dart run bin/main.dart version --json
# {"version": "0.2.0"}

dart run bin/main.dart greetings hello --name World
# greeting: Hello, World!

dart run bin/main.dart greetings hello --name World --json
# {"greeting": "Hello, World!"}
```

See [`example/`](example/) for a full working example with root commands and two modules (greetings + math).

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
actually apply. A command that declares no `params` keeps parsing its arguments
by hand and is neither described nor enforced.

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

`help --json` is the machine-readable twin of the text help: every command with
its route, description and parameters (name, aliases, type, required, default,
allowed), plus the global options.

A `help` command you register yourself always wins over the built-in one.

---

## Features

- `Command<I, O>` — pure business logic, no I/O concerns
- `CliParam` — a command's declared contract: renders help *and* enforces parsing
- Native help — `help`, no args, `--help`/`-h` on stdout with exit 0; `help --json` for machines
- `Input` / `Output` — typed DTOs for command I/O
- `CommandException` — structured errors with code, message, exit code, and retryable flag
- `ModularCli` + `ModuleBuilder` — module registration and routing
- Root commands — register commands without a module prefix via `cli.command()`
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

Or add it manually to `pubspec.yaml`:

```yaml
dependencies:
  modular_cli_sdk: ^0.3.0
```

```bash
dart pub add modular_cli_sdk
```

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
ModularCli → Module → Command → Business Logic → Output → formatted terminal output
```

- **Command layer** — pure logic, independent of output format
- **Output adapter** — turns Output into JSON or plain text based on flags/TTY
- **Middleware** — cross-cutting concerns (logging, auth, metrics)

---

## Documentation

- [API reference](https://pub.dev/documentation/modular_cli_sdk/latest/) — generated dartdoc on pub.dev
- [doc/architecture.md](doc/architecture.md) — architecture overview and symmetry with modular_api
- [doc/roadmap.md](doc/roadmap.md) — planned features for upcoming releases
- [AGENTS.md](AGENTS.md) — framework guide (AI-optimized)

---

## Compile to executable

```bash
dart compile exe bin/main.dart -o build/my-cli
```

The compiled binary includes the Dart runtime and runs without the SDK installed.

---

## License

MIT © [ccisne.dev](https://ccisne.dev)
