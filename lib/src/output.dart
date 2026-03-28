/// Outbound DTO returned by a [Command] after execution.
///
/// Symmetric with `Output` in modular_api — but carries an [exitCode]
/// instead of an HTTP `statusCode`.
///
/// Subclasses must implement [toJson] and [exitCode].  [schemaFields] is
/// optional and reserved for future schema export (v0.2.0+).
///
/// ```dart
/// class GreetOutput implements Output {
///   final String greeting;
///   GreetOutput({required this.greeting});
///
///   @override
///   Map<String, dynamic> toJson() => {'greeting': greeting};
///
///   @override
///   int get exitCode => ExitCode.ok;
/// }
/// ```
abstract class Output {
  /// Generative constructor — enables `extends Output` so subclasses
  /// inherit the default [schemaFields].
  Output();

  /// Serialize the output payload to a JSON-encodable map.
  Map<String, dynamic> toJson();

  /// CLI exit code to return (0 = success).
  int get exitCode;

  /// Field metadata for future schema export.  Returns `null` by default.
  List<dynamic>? get schemaFields => null;
}
