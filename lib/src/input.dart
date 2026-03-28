/// Inbound DTO that a [Command] receives.
///
/// Symmetric with `Input` in modular_api — but deserializes from CLI
/// flags and params (`CliRequest`) instead of JSON.
///
/// Subclasses must implement [toJson].  The static factory pattern
/// `fromCliRequest` is enforced by convention (the framework calls it
/// via the factory function registered in [ModuleBuilder.command]).
///
/// ```dart
/// class GreetInput implements Input {
///   final String name;
///   GreetInput({required this.name});
///
///   factory GreetInput.fromCliRequest(CliRequest req) =>
///       GreetInput(name: req.flagString('name') ?? 'World');
///
///   @override
///   Map<String, dynamic> toJson() => {'name': name};
/// }
/// ```
abstract class Input {
  /// Generative constructor — enables `extends Input` so subclasses
  /// inherit the default [schemaFields].
  Input();

  /// Serialize the input payload to a JSON-encodable map.
  Map<String, dynamic> toJson();

  /// Field metadata for future schema export.  Returns `null` by default.
  List<dynamic>? get schemaFields => null;
}
