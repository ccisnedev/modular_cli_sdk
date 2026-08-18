import 'command.dart';

/// A [Command] that can say **why** it built no steps.
///
/// Opt-in, and deliberately not a member of [Command]. Most commands cannot
/// produce an empty plan at all, and making all of them write `=> null` would
/// tax every command forever for something few of them have to say — which is
/// also how a member stops being read.
///
/// Without it the framework can only report *that* nothing would change. The
/// command is the only one that knows *why*, and the why is the part worth
/// reading: "no AI coding host found — pass `--host` to install into one
/// anyway" tells a caller what to do next, and "nothing would change" does not.
///
/// Read once, immediately after `steps()` returns, which is where a command
/// naturally works this out:
///
/// ```dart
/// class UpgradeCommand
///     implements Command<UpgradeInput, UpgradeOutput>, ExplainsNothingToDo {
///   String? _reason;
///
///   @override
///   Future<List<Step>> steps() async {
///     if (latest == currentVersion) {
///       _reason = 'Already on the latest version';
///       return const [];
///     }
///     …
///   }
///
///   @override
///   String? get nothingToDo => _reason;
/// }
/// ```
///
/// The reason reaches `--plan` and `--apply` alike, because both render the
/// same `PlanDocument`.
abstract interface class ExplainsNothingToDo {
  /// Why this command built no steps, in the words a caller should read.
  ///
  /// Consulted only when the plan came out empty. Return `null` to accept the
  /// framework's `nothing would change` — a command with nothing to add should
  /// not be made to invent something.
  String? get nothingToDo;
}
