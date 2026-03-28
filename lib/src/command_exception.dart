import 'exit_codes.dart';

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
///   code: 'TICKET_NOT_FOUND',
///   message: 'Ticket #42 does not exist or you lack access',
///   exitCode: ExitCode.notFound,
/// );
/// ```
class CommandException implements Exception {
  /// Machine-readable error identifier (e.g. `'TICKET_NOT_FOUND'`).
  final String code;

  /// Human-readable explanation of what went wrong.
  final String message;

  /// CLI exit code to return when this error reaches the top level.
  final int exitCode;

  /// Whether a retry might succeed (e.g. transient network failure).
  final bool isRetryable;

  /// Optional structured payload (validation errors, context, etc.).
  final Map<String, dynamic>? details;

  CommandException({
    required this.code,
    required this.message,
    this.exitCode = ExitCode.genericError,
    this.isRetryable = false,
    this.details,
  });

  /// Serialize to a JSON-friendly map.
  Map<String, dynamic> toJson() {
    return {
      'error': code,
      'message': message,
      'exitCode': exitCode,
      'isRetryable': isRetryable,
      if (details != null) 'details': details,
    };
  }

  @override
  String toString() => 'CommandException($exitCode): $message [$code]';
}
