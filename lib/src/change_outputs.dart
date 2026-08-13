import 'exit_codes.dart';
import 'output.dart';
import 'plan.dart';

/// The answer to `--plan`: what would change, and where the plan was filed.
///
/// Produced by the framework rather than by the command. A command's own
/// `Output` describes what it did; under `--plan` it did nothing, and modelling
/// "nothing happened" in every command's DTO is how `message`, `planPath` and
/// `blocked` ended up in a dozen outputs that had no business carrying them.
class PlanOutput extends Output {
  PlanOutput(this.plan, {this.filedAt});

  final PlanDocument plan;

  /// Where the host filed the plan, when it filed it.
  final String? filedAt;

  @override
  Map<String, dynamic> toJson() => {
    ...plan.toJson(),
    if (filedAt != null) 'filedAt': filedAt,
  };

  @override
  String? toText() => [
    plan.text,
    '',
    if (filedAt != null) '  written  $filedAt',
    'Nothing was changed. Re-run with --apply to carry this out, or',
    '`--apply --autoapprove` where nobody is at the keyboard.',
  ].join('\n');

  @override
  int get exitCode => ExitCode.ok;
}

/// The answer to `--apply` when the plan turned out to change nothing.
///
/// An empty plan has nothing to approve, so nobody is asked. Putting the
/// question anyway made a person answer `y/N` about no change at all, and — on
/// a run with no terminal — failed an invocation that had nothing to fail at.
///
/// It is not a failure: the caller asked for a state, and the state is already
/// the one asked for.
class NothingToDoOutput extends Output {
  NothingToDoOutput(this.plan);

  final PlanDocument plan;

  @override
  Map<String, dynamic> toJson() => {
    ...plan.toJson(),
    'applied': false,
    'reason': 'nothing would change',
  };

  @override
  String? toText() =>
      '${plan.text}\n\nNothing to apply, so nothing was asked and nothing was '
      'changed.';

  @override
  int get exitCode => ExitCode.ok;
}

/// The answer when `--apply` asked and the answer was no — or when there was
/// nobody to ask.
///
/// Non-zero: the caller asked for something to happen and it did not.
class DeclinedOutput extends Output {
  DeclinedOutput(this.reason);

  final String reason;

  @override
  Map<String, dynamic> toJson() => {'applied': false, 'reason': reason};

  @override
  String? toText() => reason;

  @override
  int get exitCode => ExitCode.genericError;
}
