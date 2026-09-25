import 'dart:async';

import 'command_exception.dart';

/// The invocation-local record of "what error, if any, should this
/// [run] call render", carried through a [Zone] rather than kept on
/// [ModularCli] as an instance field.
///
/// Round-6 review findings 1 through 3: an instance field
/// (`_pendingMiddlewareError`, the round-5 fix) is shared by every call to
/// [ModularCli.run] on the same instance, so a recursive call (a handler
/// that itself calls `cli.run(...)` with its own sinks) or two concurrent
/// calls step on each other's recorded error, and nothing about an instance
/// field says "discard this if the invocation actually recovered" versus
/// "this is what terminated it". A fresh [InvocationOutcome], created by
/// [runWithInvocationOutcome] once per [ModularCli.run] call and reachable
/// only through the zone that call establishes, fixes both: it cannot leak
/// into a sibling or a parent invocation's zone, and [ModularCli.run] reads
/// it only after the whole dispatch has finished, once, deciding then
/// whether to render it at all.
///
/// No SDK code path writes an error to stderr directly any more: a
/// handler's thrown [CommandException], an approval refusal, a failed step
/// and a middleware boundary all call [recordInvocationError] instead, and
/// [ModularCli.run] is the only place that ever turns the outcome into
/// actual output, exactly once, after the fact.
class InvocationOutcome {
  /// The most recently recorded error, or `null` when nothing has been
  /// recorded yet (or a later recording overwrote it, see
  /// [recordInvocationError]).
  CommandException? error;

  /// The output mode the request that recorded [error] was running under.
  /// Meaningless while [error] is `null`.
  bool jsonMode = false;

  /// Extra text-mode-only text to render after [error] (a shortcut or
  /// route's own contract, offered as the "you were one flag away"
  /// context [ModuleBuilder] adds in text mode). Always cleared when a new
  /// error is recorded, so it can never end up attached to a different
  /// error than the one it was recorded for.
  String? extraText;

  /// Extra JSON-mode-only fields merged into the rendered `"error"`
  /// object, alongside [CommandException.toJson]'s own
  /// `id`/`message`/`exitCode`/`details` (a rejection's own `contract`,
  /// for instance). Always cleared when a new error is recorded, for the
  /// same reason [extraText] is.
  Map<String, dynamic>? extraJson;
}

/// Zone key for the current invocation's [InvocationOutcome]. Private so
/// nothing outside this library can read or forge a zone value under it.
final Object _invocationOutcomeKey = Object();

/// Runs [body] inside a fresh [Zone] carrying its own, new
/// [InvocationOutcome], reachable through [currentInvocationOutcome] for the
/// whole extent of [body], including every `await` inside it: a [Zone]
/// value is preserved across async gaps automatically, which is exactly why
/// this uses a zone rather than an instance field or a global variable.
///
/// A nested call to this function (a handler that calls `cli.run(...)`
/// again while already inside one [run] call) creates a child zone whose
/// own [InvocationOutcome] shadows the parent's only until that nested
/// [body] returns; the parent's own outcome is untouched by anything
/// recorded inside the child, and is exactly as this call left it once
/// control returns to it.
Future<T> runWithInvocationOutcome<T>(Future<T> Function() body) {
  return runZoned(body, zoneValues: {_invocationOutcomeKey: InvocationOutcome()});
}

/// The current invocation's [InvocationOutcome].
///
/// Throws [StateError] outside a [runWithInvocationOutcome] zone: there is
/// no fallback outcome to hand back, silently, to code that calls this
/// without having gone through [ModularCli.run] first, that would be
/// exactly the kind of silent default this SDK's error rendering must not
/// have.
InvocationOutcome currentInvocationOutcome() {
  final outcome = Zone.current[_invocationOutcomeKey];
  if (outcome == null) {
    throw StateError(
      'No invocation outcome in scope. recordInvocationError and '
      'currentInvocationOutcome only work inside ModularCli.run(), which '
      'establishes the zone they read and write through '
      'runWithInvocationOutcome().',
    );
  }
  return outcome as InvocationOutcome;
}

/// Records [error] as the current invocation's outcome, replacing whatever
/// was recorded before (from an inner boundary this call's caller is
/// unwinding past) and clearing any [InvocationOutcome.extraText] that went
/// with it, so it never survives attached to a different error.
///
/// Called by every SDK path that used to write an error to stderr directly:
/// [ModuleBuilder]'s handling of a thrown [CommandException], an approval
/// refusal, a failed step, and [ModularCli.use]'s own middleware boundary.
/// None of them render anything themselves any more; [ModularCli.run]
/// decides, once, after the whole dispatch finishes, whether the final
/// exit code is nonzero and, only then, renders whichever error was
/// recorded last.
///
/// "Last recorded wins" is exactly "the outermost one wins": nested
/// middleware boundaries unwind innermost first, so an inner failure
/// recorded here and later escalated by an outer boundary is overwritten
/// by the outer's own call before [ModularCli.run] ever reads it, and an
/// inner failure an outer boundary instead recovers from (returning 0) is
/// simply never read at all, since [ModularCli.run] only renders when the
/// final exit code is nonzero.
void recordInvocationError(CommandException error, {required bool jsonMode}) {
  final outcome = currentInvocationOutcome();
  outcome.error = error;
  outcome.jsonMode = jsonMode;
  outcome.extraText = null;
  outcome.extraJson = null;
}

/// Attaches [text] to the error most recently recorded by
/// [recordInvocationError], to render after it in text mode only. Must be
/// called after the [recordInvocationError] call for the same error, in the
/// same synchronous continuation, so nothing else can record a different
/// error (and clear this) in between.
void recordInvocationExtraText(String text) {
  currentInvocationOutcome().extraText = text;
}

/// Attaches [fields] to the error most recently recorded by
/// [recordInvocationError], merged into the rendered `"error"` object in
/// JSON mode only. Must be called after the [recordInvocationError] call
/// for the same error, in the same synchronous continuation, for the same
/// reason [recordInvocationExtraText] must be.
void recordInvocationExtraJson(Map<String, dynamic> fields) {
  currentInvocationOutcome().extraJson = fields;
}

/// Clears the current invocation's recorded outcome: called at the start of
/// every dispatch attempt that can itself be retried, so a fresh attempt
/// never inherits an error a superseded attempt left behind.
///
/// Round-7 review finding 1: a middleware that retries by calling `next`
/// more than once decides to retry from a plain, already-converted exit
/// code, never from a caught exception (ModuleBuilder._mount()'s own
/// boundary never lets a CommandException propagate past it). If the first
/// attempt threw, its error is recorded by that boundary; if the retried,
/// final attempt then succeeds outright, nothing overwrites that recorded
/// error, and ModularCli.run() would render it even though the exit code it
/// returns is the final attempt's own, unrelated one. Calling this at the
/// start of each dispatch attempt, both in ModuleBuilder._mount()'s
/// handler and in ModularCli.use()'s own wrapper, means a superseded
/// attempt's error cannot outlive that attempt: only what the final
/// attempt itself records, if anything, is left for run() to read back.
void beginInvocationAttempt() {
  final outcome = currentInvocationOutcome();
  outcome.error = null;
  outcome.jsonMode = false;
  outcome.extraText = null;
  outcome.extraJson = null;
}
