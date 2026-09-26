import 'dart:async';

import 'command_exception.dart';

/// One dispatch level's own recorded outcome: what [InvocationOutcome]
/// keeps a stack of, one frame per nested `next()` call (round-8 review
/// finding 2).
class _OutcomeFrame {
  CommandException? error;
  bool jsonMode = false;
  String? extraText;
  Map<String, dynamic>? extraJson;
}

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
///
/// Round-8 review finding 2: a single flat record per invocation meant the
/// only way to keep a retried dispatch attempt from inheriting a superseded
/// attempt's error was to reset it at the start of every attempt
/// (`beginInvocationAttempt`, round-7's own fix) but that reset could not
/// tell "a superseded downstream attempt" apart from "the enclosing
/// middleware's own error, recorded before it even called `next()`", and
/// erased both alike. [InvocationOutcome] is now a stack of frames, one per
/// nested dispatch level: [pushFrame], called right before a middleware's
/// wrapped `next` actually runs, starts that downstream attempt with a
/// clean frame of its own; [popFrame], called once that attempt returns,
/// folds it back into the frame below, overwriting the enclosing level's
/// own recorded error only when the downstream frame actually recorded one
/// itself, and leaving the enclosing level's own error untouched otherwise.
/// [error], [jsonMode], [extraText] and [extraJson] always read and write
/// the current top frame, so every existing call site keeps working
/// unchanged.
class InvocationOutcome {
  final List<_OutcomeFrame> _frames = [_OutcomeFrame()];

  _OutcomeFrame get _top => _frames.last;

  /// The most recently recorded error, or `null` when nothing has been
  /// recorded yet at this dispatch level (or a later recording overwrote
  /// it, see [recordInvocationError]).
  CommandException? get error => _top.error;
  set error(CommandException? value) => _top.error = value;

  /// The output mode the request that recorded [error] was running under.
  /// Meaningless while [error] is `null`.
  bool get jsonMode => _top.jsonMode;
  set jsonMode(bool value) => _top.jsonMode = value;

  /// Extra text-mode-only text to render after [error] (a shortcut or
  /// route's own contract, offered as the "you were one flag away"
  /// context [ModuleBuilder] adds in text mode). Always cleared when a new
  /// error is recorded, so it can never end up attached to a different
  /// error than the one it was recorded for.
  String? get extraText => _top.extraText;
  set extraText(String? value) => _top.extraText = value;

  /// Extra JSON-mode-only fields merged into the rendered `"error"`
  /// object, alongside [CommandException.toJson]'s own
  /// `id`/`message`/`exitCode`/`details` (a rejection's own `contract`,
  /// for instance). Always cleared when a new error is recorded, for the
  /// same reason [extraText] is.
  Map<String, dynamic>? get extraJson => _top.extraJson;
  set extraJson(Map<String, dynamic>? value) => _top.extraJson = value;

  /// Starts a fresh, empty frame for a downstream dispatch attempt about to
  /// run (a middleware's wrapped `next()` call): see [popFrame].
  void pushFrame() => _frames.add(_OutcomeFrame());

  /// Ends the frame the matching [pushFrame] started, and reports whether
  /// it recorded an error of its own. When it did, the frame below (now
  /// the top of the stack again) is overwritten with its `error`,
  /// `jsonMode`, `extraText` and `extraJson`. When it did not, the frame
  /// below is left completely untouched by this call: what "preserved"
  /// means in that case is a call-site decision, not this class's (see
  /// [ModularCli.use], which restores its own pre-`next()` baseline rather
  /// than leaving behind whatever a previous, superseded attempt at the
  /// same dispatch level already merged in).
  bool popFrame() {
    if (_frames.length < 2) {
      throw StateError(
        'popFrame() called with no matching pushFrame(): the outcome '
        'frame stack must never drop below its base frame.',
      );
    }
    final finished = _frames.removeLast();
    if (finished.error == null) return false;
    _top
      ..error = finished.error
      ..jsonMode = finished.jsonMode
      ..extraText = finished.extraText
      ..extraJson = finished.extraJson;
    return true;
  }
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
