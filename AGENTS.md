# modular_cli_sdk — Framework Guide

> SDK for building modular CLIs with Dart.  Built on `cli_router`.

## Architecture

```
dart:io / Process           — I/O primitive
       ↓
cli_router                  — routing engine (routes, GNU flags, middleware)
       ↓
modular_cli_sdk             — SDK/framework
       ↓
ModularCli                  — entry point that orchestrates modules
  └── ModuleBuilder         — registers Commands in a module
        └── Command<I, O>   — unit of work (Input → validate → execute → Output)
```

## Core types

| Type | Purpose |
|------|---------|
| `ModularCli` | Entry point. Registers modules, applies middleware, runs `args`. |
| `ModuleBuilder` | Registers `Command`s within a named module. |
| `Command<I, O>` | Abstract unit of work: `input → validate() → execute() → Output`. |
| `Input` | Inbound DTO. Subclass and add a `fromCliRequest(CliRequest)` factory. |
| `Output` | Outbound DTO. Must implement `toJson()` and `exitCode`. |
| `CommandException` | Structured error with `code`, `message`, `exitCode`, `isRetryable`, `details`. |
| `ExitCode` | Semantic exit code constants (0, 1, 2, 4, 5, 6, 7, 64). |
| `CliOutput` | Abstract output formatter. Concrete: `JsonCliOutput`, `TextCliOutput`. |

## Command lifecycle

```
1. Framework deserializes Input from CliRequest (via factory)
2. Framework builds Command from Input (via factory)
3. validate() → returns error string or null
4. execute() → returns Output
5. Framework formats Output.toJson() through CliOutput
6. Framework returns Output.exitCode
```

## Patterns

### Creating a module

```dart
final cli = ModularCli();
cli.module('ticket', (m) {
  m.command<ListInput, ListOutput>(
    'list',
    (req) => ListTicketsCommand(ListInput.fromCliRequest(req)),
    description: 'List tickets',
  );
});
await cli.run(args);
```

### Input/Output DTOs

```dart
class ListInput extends Input {
  final int limit;
  ListInput({required this.limit});

  factory ListInput.fromCliRequest(CliRequest req) =>
      ListInput(limit: req.flagInt('limit') ?? 10);

  @override
  Map<String, dynamic> toJson() => {'limit': limit};
}

class ListOutput extends Output {
  final List<Map<String, dynamic>> tickets;
  ListOutput({required this.tickets});

  @override
  Map<String, dynamic> toJson() => {'tickets': tickets};

  @override
  int get exitCode => ExitCode.ok;
}
```

### Throwing structured errors

```dart
throw CommandException(
  code: 'TICKET_NOT_FOUND',
  message: 'Ticket #42 does not exist',
  exitCode: ExitCode.notFound,
);
```

### Global flags

- `--json` — output as JSON instead of plain text
- `--quiet` / `-q` — suppress informational messages

## Exit codes

| Code | Meaning |
|------|---------|
| 0 | OK |
| 1 | Generic error |
| 2 | External API / server error |
| 4 | Resource not found |
| 5 | Not authorized |
| 6 | State conflict |
| 7 | Validation failed |
| 64 | Invalid usage / command not found |

## Build & test

```bash
dart pub get
dart analyze
dart test
dart run example/example.dart greetings hello --name World
```

## Conventions

- Input/Output follow the same pattern as `modular_api`'s `Input`/`Output`
- Commands never write to stdout directly — they return data
- One Command per use case, one module per domain noun
- Use `extends` (not `implements`) for Input and Output subclasses
