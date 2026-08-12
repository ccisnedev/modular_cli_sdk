import 'package:cli_router/cli_router.dart';

import 'cli_param.dart';

/// Which of the two things the caller asked for.
enum ChangeMode {
  /// Show what would change, and change nothing.
  plan,

  /// Show it, take approval, then do it.
  apply,
}

/// The three flags every [Command] carries, parsed and validated together.
///
/// They are validated as a set because every rule spans more than one of them:
/// exactly one of `--plan` / `--apply`, and `--autoapprove` only alongside
/// `--apply`. A per-flag check could not see any of that.
///
/// A command author never writes these. The framework declares them on every
/// command and rejects them on every [Query], which is what makes "this command
/// changes something" a fact about the registration rather than a comment.
class ChangeFlags {
  const ChangeFlags({
    this.plan = false,
    this.apply = false,
    this.autoapprove = false,
  });

  factory ChangeFlags.fromCliRequest(CliRequest req) => ChangeFlags(
    plan: req.flagBool('plan'),
    apply: req.flagBool('apply'),
    autoapprove: req.flagBool('autoapprove'),
  );

  final bool plan;
  final bool apply;
  final bool autoapprove;

  /// Appended to every command's declared parameters.
  ///
  /// `--plan` is declared rather than being "the default, and so not declared":
  /// a default decides for the caller, and an undeclared flag cannot be typed
  /// even when every document says to.
  static final List<CliParam> params = [
    CliParam.boolean(
      'plan',
      description: 'Show what would change; change nothing',
    ),
    CliParam.boolean(
      'apply',
      description: 'Show what would change, take approval, then do it',
    ),
    CliParam.boolean(
      'autoapprove',
      description:
          'With --apply, act without asking — for agents and CI, where '
          'nobody is at the keyboard to approve',
    ),
  ];

  /// The usage error, or null when the combination is legal.
  ///
  /// Checked before a single step is built, so nothing is computed and no
  /// process is reached before the caller has said which of the two they meant.
  String? validate() {
    if (plan && apply) {
      return 'Choose one: --plan shows what would change, --apply does it. '
          'Passing both says nothing about which you meant.';
    }
    // Before the "neither" rule, so that an invocation which *did* name a flag
    // is told about the flag it named. Falling through to the general message
    // would answer "choose one" to somebody who had chosen something — just not
    // something that acts on its own.
    if (autoapprove && !apply) {
      return '--autoapprove transfers an approval that only --apply asks for. '
          'On its own it authorizes nothing — pass --apply --autoapprove to '
          'act without being asked.';
    }
    if (!plan && !apply) {
      return 'Choose --plan or --apply.\n'
          '  --plan   show what would change; nothing is touched\n'
          '  --apply  show it, ask for approval, then do it\n'
          '\n'
          'Neither is the default: a command that changes things does not '
          'decide for you which one you wanted.';
    }
    return null;
  }

  /// Valid only once [validate] has returned null.
  ChangeMode get mode => plan ? ChangeMode.plan : ChangeMode.apply;
}
