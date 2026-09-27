/// Structured error thrown during [Command] execution.
///
/// Analogous to `UseCaseException` in modular_api — but maps to CLI exit
/// codes instead of HTTP status codes.
///
/// The framework's error middleware catches these, formats them according
/// to the active output mode (JSON / plain text), and returns the
/// corresponding [exitCode].
///
/// ```dart
/// throw CommandException(
///   id: 'ticket-not-found',
///   message: 'Ticket #42 does not exist or you lack access',
///   exitCode: ExitCode.notFound,
/// );
/// ```
class CommandException implements Exception {
  /// Machine-readable error identifier, e.g. `'ticket-not-found'`.
  ///
  /// Always kebab-case (lowercase words separated by single hyphens): the
  /// same vocabulary a router-level rejection's id is drawn from, so a
  /// `--json` consumer parses one error shape regardless of which of the
  /// two raised it.
  final String id;

  /// Human-readable explanation of what went wrong.
  final String message;

  /// CLI exit code to return when this error reaches the top level.
  final int exitCode;

  /// Extra structured fields the error carries beyond [id], [message] and
  /// [exitCode]: a validation failure's `parameter`, or a domain error's own
  /// fields (a calculatrix parse error's `token` and `position`, for
  /// instance). Present in the JSON envelope only when set, nested under
  /// `"details"`.
  final Map<String, dynamic>? details;

  /// Fields a domain error contributes at the top level of the rendered
  /// `"error"` object, alongside [id]/[message]/[exitCode]/[details], not
  /// nested under either of them (`doctor`'s own `"checks"` array, for
  /// instance). Its keys must not collide with a name the envelope itself
  /// already writes (see [_reservedFieldNames]): the constructor rejects
  /// that at construction time, rather than let a later spread silently
  /// overwrite a validated field.
  ///
  /// Distinct from `InvocationOutcome.extraJson`: that is the rendering
  /// layer's own carrier, filled in from this field by
  /// `recordInvocationError` right after the error is recorded (round-12
  /// review finding 1: every recording path does this now, not only
  /// `ModuleBuilder._reject`). A thrower sets [extraFields] here, on the
  /// exception itself, never on the outcome directly, since a thrown
  /// exception has already left the thrower's own stack frame by the time
  /// anything could record it.
  ///
  /// Always the constructor's own defensive, unmodifiable copy of whatever
  /// map the caller passed in, never the caller's own map reference (Codex
  /// review of 53aeb3f found this: the constructor used to keep the
  /// caller's own mutable map, validated once at construction time, so a
  /// caller mutating that map afterwards, or an unrelated holder of the
  /// same reference, could corrupt the rendered envelope after validation
  /// already passed). Attempting to mutate this map throws
  /// [UnsupportedError], the same as any other unmodifiable map.
  final Map<String, dynamic>? extraFields;

  /// Text a domain error contributes after the rendered error line in text
  /// mode, exactly as [extraFields] does for JSON mode, and forwarded the
  /// same way, through `recordInvocationError` into
  /// `InvocationOutcome.extraText`.
  final String? extraLines;

  static final _kebabCase = RegExp(r'^[a-z0-9]+(-[a-z0-9]+)*$');

  /// The envelope field names [toJson] always writes, whatever the
  /// instance: the fixed keys an [extraFields] entry must never collide
  /// with, since the SDK's own renderer spreads [extraFields] over
  /// [toJson]'s own output (`ModularCli._renderRecordedError`), so a
  /// colliding key would silently overwrite a validated field with
  /// whatever [extraFields] set instead (round-12 review finding 2, PR
  /// #30).
  ///
  /// Derived from [toJson] itself, on a throwaway instance with every
  /// optional field populated so its key actually appears, rather than
  /// hand-listed here where it could drift out of sync with [toJson] if a
  /// field were ever added there and this set forgotten. The probe passes
  /// no [extraFields] of its own, so building it never re-enters this same
  /// validation.
  static final Set<String> _reservedFieldNames = CommandException(
    id: 'reserved-field-probe',
    message: '',
    exitCode: 0,
    details: const {},
  ).toJson().keys.toSet();

  CommandException({
    required this.id,
    required this.message,
    required this.exitCode,
    this.details,
    Map<String, dynamic>? extraFields,
    this.extraLines,
  }) : extraFields = extraFields == null
           ? null
           // A defensive copy, taken before any validation below runs and
           // before this constructor ever returns: extraFields, from here
           // on, is this exception's own unmodifiable map, never the
           // caller's. Mutating the caller's original map afterwards, or
           // attempting to mutate this one directly, cannot reach what
           // later gets rendered (Codex review of 53aeb3f).
           : Map<String, dynamic>.unmodifiable(extraFields) {
    if (!_kebabCase.hasMatch(id)) {
      throw ArgumentError(
        'CommandException id "$id" must be kebab-case: lowercase letters '
        'and digits, words separated by single hyphens (e.g. '
        '"ticket-not-found").',
      );
    }
    if (this.extraFields != null) {
      final collisions = this.extraFields!.keys
          .where(_reservedFieldNames.contains)
          .toList();
      if (collisions.isNotEmpty) {
        throw ArgumentError(
          'CommandException extraFields must not use the reserved '
          'envelope field name(s) ${collisions.join(', ')}: extraFields is '
          'spread over the rendered "error" object alongside its own '
          'id/message/exitCode/details, so a colliding key would silently '
          'overwrite one of them instead of adding a new one.',
        );
      }
    }
  }

  /// The error's own fields, nested exactly as they belong inside the
  /// `"error"` key of the envelope [ModularCli.run] writes in `--json`
  /// mode: see the id table in the README.
  Map<String, dynamic> toJson() => {
    'id': id,
    'message': message,
    'exitCode': exitCode,
    if (details != null) 'details': details,
  };

  @override
  String toString() => 'CommandException($exitCode): $message [$id]';
}
