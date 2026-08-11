# Roadmap — modular_cli_sdk

> What has shipped, and what is being considered next.
> For the detail of any release, read [`CHANGELOG.md`](../CHANGELOG.md) — it is
> the record. This file exists to show the shape of the thing over time, not to
> restate it.

---

## Shipped

Version numbers here are the subject, not metadata: each names a release that
exists on pub.dev.

| Version | What it added |
| --- | --- |
| **0.1.0** | The core framework — `ModularCli`, `ModuleBuilder`, `Command<I, O>`, `Input`/`Output`, `CommandException`, `ExitCode`, and the `CliOutput` implementations |
| **0.2.0** | Root commands — `ModularCli.command<I, O>()`, registering commands with no module prefix, on the same lifecycle |
| **0.2.1** | `Output.toText()`, for a command that wants to format its own text |
| **0.3.0** | The command contract — `CliParam` declared on the `Input`, native help on stdout with exit 0, focused help per command and per module, `help --json`, and enforcement: the declaration governs parsing |
| **0.3.1** | A registered root route owns the empty invocation |
| **0.3.2** | An empty contract is a declaration, not an absence |
| **0.3.3** | A command with positionals can be asked for its contract |
| **0.3.4** | An incomplete invocation is not an unknown command |

---

## Being considered

**Deliberately unnumbered.** Attaching a version to something unbuilt is a
promise that ages badly, and this file has done it before: it once announced as
planned two versions that had already shipped, promising a `Flag` class where
`CliParam` was built and a `CliConfig` that does not exist. What follows is the
direction, not a commitment to a release.

### Layered configuration

Resolution with a precedence chain — flag over environment over project over
user over default — plus persistent context and profiles. The largest item here,
and the one most likely to want its own design discussion first.

### More output formats

`--format` for table, csv, tsv and single-value output; column alignment;
a tsv fallback when the output is piped and there is no TTY.

### Interactivity

Prompting for missing required arguments when a TTY is present, with `--yes` to
skip confirmations and `--non-interactive` to disable prompting entirely for
CI/CD.

### Shell completions

Generated from the command catalog, which already holds every route and every
declared parameter — bash, zsh, fish, PowerShell.

### Further out

Command aliases; a plugin system for third-party command modules; opt-in
telemetry hooks.
