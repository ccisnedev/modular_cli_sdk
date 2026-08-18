# 3. Adopting commands changes everything that ever typed them

Date: 2026-08-18

## Status

Accepted

## Context

Two hosts have now migrated to
[ADR 2](0002-a-command-previews-through-a-separate-method.md):

| Host | Version | Queries | Commands |
| --- | --- | --- | --- |
| macss | 0.9.x → 0.10.1 | 12 | 18 |
| inquiry | 0.24.1 → 0.25.1 | 9 | 5 |

Rewriting the units went as designed. `execute()` became `steps()` and
`describe()`, the flags and the gate stopped being per-command code, and the
three ad-hoc plan/apply strategies ADR 2 was written about disappeared. That
part is not what this record is about.

Three other things cost the time, and none of them lives in a command class.
Both migrations hit all three, which is what makes them worth writing down
rather than remembering.

### The invocation surface has no compiler

Changing `Command` breaks the build wherever a command is *implemented*. It
breaks nothing wherever a command is *named*. Those are different sets, and the
second is much larger.

In inquiry the second set turned out to hold: three installers, the post-install
child process an upgrade spawns, a VS Code extension, the scheduler's
instruction asset, and twelve remediation messages — among them the `INIT_HINT`
baked into the agent files already deployed into every host on every machine.

They were found in three separate rounds, each triggered by something other than
the compiler:

- the post-install child, while reading `runPostInstall` looking for something
  else. It would have made every upgrade report a failed redeploy
- the VS Code extension, on being asked whether the documentation was up to
  date. It ran a bare `host get` inside `catch { /* non-fatal */ }`, so the CLI
  would install, nothing would deploy, and the notification would still report
  success
- the twelve messages, by a user running `iq upgrade` and being told
  ``Run `iq host get` to retry`` — a retry that fails for the same reason the
  deploy did

A clean analyzer run and 535 passing tests saw none of them.

Two of them had tests that passed anyway. The extension's asserted that the
arguments *contained* `host` and `get`, which the broken invocation also
satisfies. That is the shape of the whole problem: part of the contract moved
into strings, and nothing reads strings.

### An upgrade command is governed by the version it replaces

`upgrade` is the one command that runs as the *outgoing* binary. Whatever it
does — including the arguments it hands to the freshly installed one — was
frozen at the previous release. A fix to the upgrade path never fixes the
upgrade being performed; it fixes the next one.

This was learned twice.

In macss, a rewrite dropped six progress lines from `upgrade`. It was invisible
in review and in testing because the version under test never runs its own
upgrade: what a user sees comes from the version being replaced. It surfaced one
release later.

In inquiry it was worse, because the change was to the contract itself. 0.24.1's
post-install invokes a bare `host get`; 0.25.0's `host get` refuses it. The
upgrade to 0.25.0 therefore ends in a failed deploy on every machine, and
nothing shipped in 0.25.0 could have prevented it — the offending code is in the
release already installed. The remedy is one manual `host get --apply`, and the
only thing to do beforehand is know it is coming and say so.

### "Where am I" answers differently under a test harness

`Platform.resolvedExecutable` is the host's binary when a compiled binary runs.
Under `dart test` and `dart run` it is the Dart VM. macss's `ReplaceInstallation`
read it inline, and its Windows branch renames the running executable out of the
way — so the first test to exercise the real `perform()` renamed the Dart SDK's
own `dart.exe` and took the toolchain down with it.

The seam that fixes this (`runningExecutable`, injected) is obvious in hindsight
and took minutes. It was absent because nothing suggested it was needed: the
code reads correctly, and it *is* correct — in production.

## Decision

The SDK cannot enforce any of this. What it can do is state it, so the next host
does not rediscover it the way these two did. Three obligations a host takes on
when it registers its first `command`:

**1. A host sweeps its own sources for messages that name a command without a
mode.** This is a test, because a test is the only mechanism that reads strings.
It needs no hand-maintained list of command names: the catalog already knows
which routes were registered as commands, so the sweep derives them and cannot
drift from the registration.

```dart
final commands = cli.catalog
    .ofKind(CommandKind.command)
    .map((c) => c.name); // 'host get', 'upgrade', …
```

Scan the host's sources for any of those names on a non-comment line, and fail
unless `--plan` or `--apply` appears alongside. The version in inquiry
(`test/remediations_are_runnable_test.dart`) was written by reintroducing one of
the twelve messages and confirming it failed.

The rule the sweep encodes: **a message that names a command is an instruction,
and an instruction that cannot be run is worse than none** — it reads as
guidance and behaves as a wall. Which mode to name follows from who acts on it.
A person at a terminal gets `--apply`. An installer or agent acting unattended
gets `--apply --autoapprove`, because there is nobody to answer the prompt.
Only an invitation to look first gets `--plan`.

**2. The arguments a self-replacing command hands to its child are a published
constant, pinned by a test.** In inquiry this is `postInstallArguments`, shared
by both platform implementations so the two cannot drift. Naming it is what
makes it reviewable; pinning it is what stops a later edit from quietly dropping
the mode. And because the outgoing release governs, a host changing this must
expect one release in which the old arguments are still in use, and record it in
the changelog rather than receive it as a bug report.

**3. Anything answering "where am I" or "who am I" is a constructor seam, never
read inline.** `Platform.resolvedExecutable`, `Directory.current`,
`Platform.environment`. The question is not whether the call is correct — it is
whether the call *means the same thing* inside a test harness. These do not.

This SDK holds itself to the same rule where it can: `ModularCli` is handed its
`Approver` and `PlanSink` rather than reaching for a terminal.

## Consequences

**Easier**

- A host adopting this SDK gets a checklist for the part that is not mechanical,
  instead of discovering it in production
- The sweep derives from the catalog, so registering a new command extends the
  check automatically. The failure mode is a test failure, not a new blind spot

**Harder**

- Each host writes and owns its sweep. The SDK cannot ship it: it would have to
  read the host's own sources, and a package that reads its consumer's source
  tree is the wrong shape
- Migrating a CLI is now correctly understood to be more work than it looks.
  That is a truer estimate, not a heavier one

**Deliberately left out**

- A lint or codegen that flags command names inside string literals. It would
  have to tell a message apart from a comment, a changelog entry, and a doc
  comment quoting historical behaviour. The sweep does that in a few lines the
  host can tune, and a general version would be harder to configure than to
  write
- Any grace period in which `--plan`/`--apply` stays optional. The whole value
  of ADR 2 is that a command cannot skip the gate; a grace mode would be the
  `dryRun` flag ADR 2 removed, wearing a different name
