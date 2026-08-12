# 2. A command previews through a separate method, not a dry-run flag

Date: 2026-08-12

## Status

Accepted

## Context

Until now this SDK knew one kind of unit: `Command`, with `validate()` and
`execute()`. Every registered route was one, whether it read or wrote.

That left two things unsaid.

**There was no way to tell a reading command from a writing one.** `modular_api`
gets this from its transports — GraphQL publishes reads, REST publishes the full
use case — so the distinction is imposed by *where* a use case is published. A
CLI has one transport, `argv`, so nothing imposes it. The result was that
"changes nothing" could only be written down in prose. In the CLI built on this
SDK it literally was: `requisition list` carries a comment saying it declares
neither `--plan` nor `--apply` and rejects both.

**There was no way to show what a command would do before it did it.** Hosts
solved it themselves, and the same host solved it three different ways:

1. a `dryRun: true` boolean threaded into the worker, which then runs the same
   traversal twice — `skill deploy`
2. the preview loop and the doing loop written out separately, character for
   character — `skill clean`
3. computing the answer for the preview and computing it again for the work —
   `requisition new` calls `existsSync()` for the preview on one line and again
   for the decision forty lines later

All three work. None of them is held to anything: nothing anywhere compares what
was shown against what was done, so the two drift one commit at a time and
nobody finds out. Eleven of the thirteen writing commands in that CLI need a
value computed during the preview — a resolved template's contents, an assembled
issue body, a release URL fetched from GitHub — and each carries it across by
hand.

## Decision

**A command is an ordered list of steps, each of which states what it would do
before anything runs, and is held to it.** The engine is
[`preview_executor`](https://pub.dev/packages/preview_executor), a separate
package with no knowledge of CLIs, so `modular_api` can put the same engine
behind an endpoint's dry-run.

Two unit types, and the difference between them is structural rather than a
label:

```dart
abstract class Query<I, O> {          abstract class Command<I, O> {
  String? validate();                   String? validate();
  Future<O> execute();                  Future<List<Step>> steps();
}                                       O describe(Execution execution);
                                      }
```

A query has no preview because it has nothing to preview. A command has one
because it changes something. Neither can be mistaken for the other by accident:
they share no method.

Registration says which: `m.query(...)` or `m.command(...)`. From that the SDK
derives everything that used to be repeated per command — `--plan`, `--apply`
and `--autoapprove` are declared automatically on a command and rejected
automatically on a query, the flag combinations are validated in one place, the
plan is rendered in one place, and the approval is taken in one place.

We follow Terraform's **executor** and refuse its **planner**:

| Taken | Refused |
| --- | --- |
| The plan as an ordered list of operations | A state file |
| A step that describes itself without running | Declarative desired-state config |
| What the description computed, available when it acts | A dependency graph |
| Values that cannot be known yet, declared as such | Replace / destroy / drift semantics |
| Checking what was done against what was said | Providers as out-of-process plugins |

Terraform needs the right-hand column because its problem is reconciling remote
state it does not control. This SDK's hosts have no such state: their artifacts
are files under version control, so a step reads the world when it previews and
there is nothing stale to reconcile.

**`--plan` writes a report, not an executable plan.** It is not an input to
anything: `--apply` never reads it, and re-previews immediately before acting.
This is Terraform's interactive `apply`, not its `apply tfplan`, and it is the
reason none of Terraform's staleness machinery is needed — between what is shown
and what is done there is no gap for the world to move in.

The guarantee that what was shown is what was done therefore does **not** come
from the file. It comes from the executor comparing each step's `Outcome`
against the `Preview` that step gave moments earlier, within one run.

## Consequences

**Easier**

- A command's `Output` carries only what the command produced. `message`,
  `planPath` and `blocked` — which described the gate, not the work — belong to
  the SDK now
- A step computes what it needs once, in its own constructor, so there is no
  second derivation to disagree with the first
- `--plan --json` returns a structured list of steps rather than a prose blob,
  which is what an agent consumes
- A value that cannot exist before the step runs is declared and rendered as
  *known once this runs*, instead of being silently absent from the preview

**Harder**

- This is a breaking change. Every existing `Command` is what is now a `Query`,
  and every writing command has to be rewritten as steps
- A command is more classes: an author writes step types rather than one
  `execute()` body. That cost is the point — the steps are what can be checked
- The SDK now depends on `preview_executor`, so releases are coupled

**Deliberately left out**

- Applying a plan file written by an earlier run
  (`--apply --from-plan <file>`). It is the one place Terraform's staleness
  detection would be needed, and it can be added without redesign: fingerprint
  the previews, refuse when they no longer match
