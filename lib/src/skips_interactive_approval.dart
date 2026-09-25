import 'command.dart';

/// A [Command] whose own contract is the authorization to carry a plan out,
/// so [ModuleBuilder] must not insert its usual interactive approval between
/// `--apply` and [Command.describe].
///
/// Opt-in, and rare: almost every command benefits from a human, or
/// `--autoapprove`, confirming a plan before it runs. A command implements
/// this only when naming its own route with `--apply` already is that
/// confirmation. `upgrade --apply` and `uninstall --apply` are exactly that:
/// there is no other effect requesting them can have, so asking again with a
/// rendered plan repeats a question the invocation already answered, and,
/// worse, refuses to run at all wherever no terminal is attached to answer
/// it (CI, an agent, a script), even though those callers never named
/// `--autoapprove`.
///
/// ```dart
/// class UpgradeCommand
///     implements Command<UpgradeInput, UpgradeOutput>, SkipsInteractiveApproval {
///   // --apply performs the plan without an approval prompt or --autoapprove.
/// }
/// ```
abstract interface class SkipsInteractiveApproval {}
