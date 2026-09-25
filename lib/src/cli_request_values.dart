import 'package:cli_router/cli_router.dart';

/// Typed readers over a [CliRequest]'s already-validated options.
///
/// By the time a command's `Input` factory runs, [applyDeclaredContract] has
/// already checked every option against its [CliParam] — type, allowed
/// values, path existence — and has synthesized any [DeclaredDefault] that
/// applies. These readers do not re-validate; they only give back what is
/// already known to be there, in the shape the command declared it as. A
/// declared default is never re-supplied here with `??` — once declared, it
/// is already in the request, and a second fallback in the command's own
/// code would only hide what the contract already says.
extension CliRequestValues on CliRequest {
  /// The raw value of a declared string, enumeration or path option.
  String? flagString(String name) => option(name)?.value;

  /// The value of a declared integer option, already known to parse.
  int? flagInt(String name) {
    final raw = option(name)?.value;
    return raw == null ? null : int.parse(raw);
  }

  /// The value of a declared number option, already known to parse.
  double? flagNumber(String name) {
    final raw = option(name)?.value;
    return raw == null ? null : double.parse(raw);
  }

  /// Whether a declared flag was written on this invocation.
  bool flagBool(String name) => option(name) != null;

  /// The value of a declared positional, already known to parse as an
  /// integer.
  int? positionalInt(String name) {
    final raw = param(name);
    return raw == null ? null : int.parse(raw);
  }

  /// The value of a declared positional, already known to parse as a number.
  double? positionalNumber(String name) {
    final raw = param(name);
    return raw == null ? null : double.parse(raw);
  }
}
