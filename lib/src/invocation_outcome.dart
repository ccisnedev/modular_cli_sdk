import 'dart:async';

import 'command_exception.dart';

/// One dispatch level's own recorded outcome. Round-10 review finding 1
/// replaces the round-8 fix's shared, mutable frame stack (one push per
/// nested `next()` call, one pop to fold it back) with frames addressed
/// through a [Zone] instead: a frame is now just a plain value object, and
/// which one is "current" is decided by which zone the currently running
/// code was scheduled from, not by a stack pointer that any nested call can
/// move out from under a still-suspended caller. See [InvocationOutcome] for
/// why that distinction matters.
class _OutcomeFrame {
  CommandException? error;
  bool jsonMode = false;
  String? extraText;
  Map<String, dynamic>? extraJson;

  /// The sequence number [error] was recorded at (see
  /// [InvocationOutcome.recordedAt]), 0 when nothing has been recorded into
  /// this frame yet.
  int recordedAt = 0;
}

/// A snapshot of one [_OutcomeFrame], handed back across the boundary
/// [InvocationOutcome.runAttempt] returns through: callers outside this
/// library see this record, never the private frame object itself.
typedef RecordedOutcome = ({
  CommandException error,
  bool jsonMode,
  String? extraText,
  Map<String, dynamic>? extraJson,
  int recordedAt,
});

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
/// erased both alike. A stack of frames, one per nested dispatch level,
/// fixed that (round-8 through round-9's own fixes, superseded below).
///
/// Round-10 review finding 1: that frame stack was still one shared,
/// mutable object, addressed by a "topmost frame" pointer that a nested
/// `next()` call moved by calling [pushFrame] synchronously, before its own
/// first `await`. A middleware that starts `pending = next(req)` without
/// awaiting it yet, then records its own error in that same synchronous
/// continuation (a legitimate, supported pattern: recording does not
/// require awaiting first), was recording into whatever the topmost frame
/// happened to be at that instant, the freshly pushed downstream frame,
/// not its own. A later silent retry then folded that downstream frame
/// away as "nothing recorded this attempt", discarding the middleware's own
/// recording along with it: no envelope at all.
///
/// The fix drops the shared stack entirely. There is no "topmost frame"
/// lookup left anywhere in this file: [error], [jsonMode], [extraText],
/// [extraJson] and [recordedAt] all resolve "the current frame" through
/// [Zone.current], and the only code that ever introduces a new frame is
/// [runAttempt], called once per `next()` attempt, which runs its body
/// inside a freshly zoned frame reachable for that attempt's whole dynamic
/// extent, including every `await` inside it and every further nested
/// middleware or handler it goes on to call. Code that is not running
/// inside some attempt's zone (a middleware's own continuation, before its
/// first `next()` call, between two of them, after the last one, or purely
/// concurrently while one is still pending) resolves to whichever frame was
/// already ambient before that attempt started: its own enclosing level's
/// frame, exactly the one its caller will read once it returns. A
/// concurrent recording from the middleware's own code and one from a
/// pending attempt can therefore never collide: each lands in its own,
/// separately addressed slot, and [runAttempt]'s caller decides which one
/// to keep by comparing [RecordedOutcome.recordedAt], the same "later
/// sequence number wins" rule [ModularCli.use] already applied before this
/// fix, now applied to two slots that can no longer be confused with one
/// another no matter how the two attempts interleave.
class InvocationOutcome {
  final _OutcomeFrame _baseFrame = _OutcomeFrame();

  /// Monotonically increasing across the whole invocation, bumped once per
  /// [recordInvocationError] call, whichever frame it lands on: the one
  /// thing that lets two recordings, made in two different frames that
  /// never see each other, still be compared by "which happened more
  /// recently". This is what [ModularCli.use] compares its own recording
  /// against a completed attempt's by (round-9 review finding 1, still true
  /// after round-10's fix).
  int _versionCounter = 0;

  /// The frame current code resolves to: whatever [runAttempt] most
  /// recently bound in the zone this call is running in, or [_baseFrame]
  /// when nothing has (code running directly inside the zone
  /// [runWithInvocationOutcome] established, with no attempt in progress).
  _OutcomeFrame get _frame =>
      (Zone.current[_currentFrameKey] as _OutcomeFrame?) ?? _baseFrame;

  /// The most recently recorded error, or `null` when nothing has been
  /// recorded yet at this dispatch level (or a later recording overwrote
  /// it, see [recordInvocationError]).
  CommandException? get error => _frame.error;
  set error(CommandException? value) => _frame.error = value;

  /// The output mode the request that recorded [error] was running under.
  /// Meaningless while [error] is `null`.
  bool get jsonMode => _frame.jsonMode;
  set jsonMode(bool value) => _frame.jsonMode = value;

  /// Extra text-mode-only text to render after [error] (a shortcut or
  /// route's own contract, offered as the "you were one flag away"
  /// context [ModuleBuilder] adds in text mode). Always cleared when a new
  /// error is recorded, so it can never end up attached to a different
  /// error than the one it was recorded for.
  String? get extraText => _frame.extraText;
  set extraText(String? value) => _frame.extraText = value;

  /// Extra JSON-mode-only fields merged into the rendered `"error"`
  /// object, alongside [CommandException.toJson]'s own
  /// `id`/`message`/`exitCode`/`details` (a rejection's own `contract`,
  /// for instance). Always cleared when a new error is recorded, for the
  /// same reason [extraText] is.
  Map<String, dynamic>? get extraJson => _frame.extraJson;
  set extraJson(Map<String, dynamic>? value) => _frame.extraJson = value;

  /// The sequence number [error] was last recorded at, at the current
  /// frame: 0 when nothing has been recorded into it. A caller that keeps
  /// its own snapshot of [error] alongside the value this returned at the
  /// time it copied it can later tell whether a newer recording has since
  /// happened elsewhere, without having to compare the [CommandException]
  /// values themselves (round-9 review finding 1).
  int get recordedAt => _frame.recordedAt;
  set recordedAt(int value) => _frame.recordedAt = value;

  /// Runs [body] as one middleware `next()` attempt, isolated in a frame of
  /// its own for that attempt's whole dynamic extent (round-10 review
  /// finding 1): a recording made anywhere inside [body], directly or
  /// through any further nested middleware or handler it calls, lands in
  /// that frame, addressed through the [Zone] [body] runs in, never in
  /// whatever frame happens to be current outside it. [onSettled] is called
  /// exactly once, whether [body] returns or throws, with a snapshot of
  /// that frame (`null` when nothing was recorded into it) so the caller
  /// can decide what to do with it; nothing is folded anywhere
  /// automatically, unlike the round-8 through round-9 [popFrame] this
  /// replaces.
  Future<T> runAttempt<T>(
    Future<T> Function() body, {
    required void Function(RecordedOutcome? recorded) onSettled,
  }) async {
    final frame = _OutcomeFrame();
    try {
      return await runZoned(body, zoneValues: {_currentFrameKey: frame});
    } finally {
      final recordedError = frame.error;
      onSettled(
        recordedError == null
            ? null
            : (
                error: recordedError,
                jsonMode: frame.jsonMode,
                extraText: frame.extraText,
                extraJson: frame.extraJson,
                recordedAt: frame.recordedAt,
              ),
      );
    }
  }
}

/// Zone key for the current invocation's [InvocationOutcome]. Private so
/// nothing outside this library can read or forge a zone value under it.
final Object _invocationOutcomeKey = Object();

/// Zone key for the frame current code should read and write, bound only by
/// [InvocationOutcome.runAttempt] (round-10 review finding 1). Absent
/// outside any attempt, in which case [InvocationOutcome._frame] falls back
/// to the invocation's base frame.
final Object _currentFrameKey = Object();

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
/// Writes into whichever frame [Zone.current] resolves to (round-10 review
/// finding 1): code running inside a [InvocationOutcome.runAttempt] call
/// records into that attempt's own frame; code running outside any of them
/// records into whatever frame was already ambient there, so a middleware's
/// own recording and a pending attempt's downstream recording can never
/// land in the same slot regardless of which one happens first.
void recordInvocationError(CommandException error, {required bool jsonMode}) {
  final outcome = currentInvocationOutcome();
  outcome.error = error;
  outcome.jsonMode = jsonMode;
  outcome.extraText = null;
  outcome.extraJson = null;
  outcome.recordedAt = ++outcome._versionCounter;
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
