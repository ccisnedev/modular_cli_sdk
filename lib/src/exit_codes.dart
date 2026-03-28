/// Semantic exit codes for CLI commands.
///
/// Maps domain error categories to numeric codes that scripts and agents
/// can interpret without parsing stderr.  Mirrors HTTP status semantics
/// where practical (e.g. 4 = not found ≈ 404, 5 = unauthorized ≈ 401).
///
/// ```
///  0  OK
///  1  Generic / unspecified error
///  2  External API or server error
///  4  Resource not found
///  5  Not authorized
///  6  State conflict (FSM transition rejected)
///  7  Validation failed (bad input)
/// 64  Invalid usage / command not found (EX_USAGE)
/// ```
class ExitCode {
  ExitCode._();

  static const ok = 0;
  static const genericError = 1;
  static const apiError = 2;
  static const notFound = 4;
  static const unauthorized = 5;
  static const conflict = 6;
  static const validationFailed = 7;
  static const invalidUsage = 64;

  /// All defined exit codes as a set — useful for testing completeness.
  static const all = {
    ok,
    genericError,
    apiError,
    notFound,
    unauthorized,
    conflict,
    validationFailed,
    invalidUsage,
  };
}
