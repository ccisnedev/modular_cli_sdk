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
  /// instance).
  ///
  /// Distinct from `InvocationOutcome.extraJson`: that is the rendering
  /// layer's own carrier, filled in from this field by
  /// `ModuleBuilder._reject` right after the error is recorded, in the same
  /// synchronous continuation ordering `InvocationOutcome` requires. A
  /// thrower sets [extraFields] here, on the exception itself, never on the
  /// outcome directly, since a thrown exception has already left the
  /// thrower's own stack frame by the time anything could record it.
  final Map<String, dynamic>? extraFields;

  /// Text a domain error contributes after the rendered error line in text
  /// mode, exactly as [extraFields] does for JSON mode, and forwarded the
  /// same way, through `ModuleBuilder._reject` into
  /// `InvocationOutcome.extraText`.
  final String? extraLines;

  static final _kebabCase = RegExp(r'^[a-z0-9]+(-[a-z0-9]+)*$');

  CommandException({
    required this.id,
    required this.message,
    required this.exitCode,
    this.details,
    this.extraFields,
    this.extraLines,
  }) {
    if (!_kebabCase.hasMatch(id)) {
      throw ArgumentError(
        'CommandException id "$id" must be kebab-case: lowercase letters '
        'and digits, words separated by single hyphens (e.g. '
        '"ticket-not-found").',
      );
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
