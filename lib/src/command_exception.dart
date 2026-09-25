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
  /// instance). Present in the JSON envelope only when set.
  final Map<String, dynamic>? details;

  static final _kebabCase = RegExp(r'^[a-z0-9]+(-[a-z0-9]+)*$');

  CommandException({
    required this.id,
    required this.message,
    required this.exitCode,
    this.details,
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
