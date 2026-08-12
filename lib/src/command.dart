import 'package:preview_executor/preview_executor.dart';

import 'input.dart';
import 'output.dart';

/// A unit of work that **changes something**, as an ordered list of steps.
///
/// Where a [Query] answers, a command acts — and because it acts, it can be
/// asked what it would do first. That is not a mode of doing the work with its
/// effects switched off: each [Step] states its intention through
/// `Step.preview()` and does its work through `Step.perform()`, and the two are
/// compared once the run is over. A preview nothing checks is a comment.
///
/// Lifecycle (managed by the framework):
///   1. Factory function builds the Command from a `CliRequest`
///   2. [validate] — return an error string, or `null` when the input is valid
///   3. `--plan` / `--apply` are validated — neither is a default
///   4. [steps] — build the ordered list
///   5. every step is previewed and the plan rendered
///   6. under `--plan` the run stops here; under `--apply` approval is taken
///      and the steps are performed in order
///   7. [describe] — turn what happened into this command's own `Output`
///
/// ```dart
/// class OpenRequisition implements Command<OpenInput, OpenOutput> {
///   @override
///   final OpenInput input;
///   OpenRequisition(this.input);
///
///   @override
///   String? validate() => input.slug.isEmpty ? 'a <slug> is required' : null;
///
///   @override
///   Future<List<Step>> steps() async => [
///     WriteFile('${input.dir}/requisition.md', await template()),
///     RecordActive(input.slug),
///   ];
///
///   @override
///   OpenOutput describe(Execution execution) =>
///       OpenOutput(dir: input.dir, changed: execution.outcomes.length);
/// }
/// ```
abstract class Command<I extends Input, O extends Output> {
  /// The validated input for this invocation.
  I get input;

  /// Validate business rules on [input].
  /// Return a human-readable error string, or `null` when valid.
  ///
  /// The `--plan` / `--apply` rules are **not** checked here — the framework
  /// applies them to every command, so no command carries them.
  String? validate();

  /// The ordered list of steps this invocation would carry out.
  ///
  /// Called once per run, whether the run previews or performs, so a step
  /// computes whatever it needs in its own constructor and the preview and the
  /// work cannot describe different changes.
  ///
  /// Reading is expected — a step decides between `create` and `keep` by
  /// looking. Writing here is not: everything that changes belongs inside a
  /// step, where it is announced first.
  Future<List<Step>> steps();

  /// This command's own `Output`, from what the run did.
  ///
  /// A pure function of [execution]. The gate's own concerns — where a plan was
  /// written, whether approval was declined, what exit code a refusal deserves —
  /// belong to the framework and are not modelled here.
  ///
  /// Called even when the run stopped early, so the command can report what it
  /// managed. Consult `execution.isComplete` and `execution.isFaithful` when
  /// that changes what there is to say.
  O describe(Execution execution);
}
