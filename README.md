[![pub package](https://img.shields.io/pub/v/modular_cli_sdk.svg)](https://pub.dev/packages/modular_cli_sdk)

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

  cli.module('greetings', (m) {
    m.command<HelloInput, HelloOutput>(
      'hello',
      (req) => HelloCommand(HelloInput.fromCliRequest(req)),
      description: 'Say hello to someone',
    );
  });

  final code = await cli.run(args);
  exit(code);
}
```

```bash
dart run bin/main.dart greetings hello --name World
# greeting: Hello, World!

dart run bin/main.dart greetings hello --name World --json
# {"greeting": "Hello, World!"}
```

See `example/example.dart` for the full implementation including Input, Output, Command, and two modules.

---

## Features

- `Command<I, O>` — pure business logic, no I/O concerns
- `Input` / `Output` — typed DTOs for command I/O
- `CommandException` — structured errors with code, message, exit code, and retryable flag
- `ModularCli` + `ModuleBuilder` — module registration and routing
- `--json` global flag — machine-readable JSON output
- `--quiet` global flag — suppress informational messages
- TTY detection — automatic format selection
- Semantic exit codes — 0 (OK), 1 (error), 4 (not found), 5 (unauthorized), 7 (validation), 64 (usage)
- Built on `cli_router` — GNU flags, middleware, modular mounting

---

## Installation

```yaml
dependencies:
  modular_cli_sdk: ^0.1.0
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

- [AGENTS.md](AGENTS.md) — Framework guide (AI-optimized)
- [doc/architecture.md](doc/architecture.md) — Architecture overview

---

## Compile to executable

```bash
dart compile exe bin/main.dart -o build/my-cli
```

---

## License

MIT © [ccisne.dev](https://ccisne.dev)
