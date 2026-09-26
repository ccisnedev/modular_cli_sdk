/// Inbound DTO that a [Command] receives.
///
/// Symmetric with `Input` in modular_api — but deserializes from CLI
/// flags and params (`CliRequest`) instead of JSON.
///
/// Subclasses must implement [toJson].  The static factory pattern
/// `fromCliRequest` is enforced by convention (the framework calls it
/// via the factory function registered in [ModuleBuilder.command]).
///
/// The contract itself (what this Input reads, with what types, defaults
/// and constraints) is declared once, separately, as a [CliContract] passed
/// to [ModuleBuilder.query] or [ModuleBuilder.command]; it is what help
/// renders from and what the framework enforces before the factory below
/// ever runs, so a value read here is already known to honour it. A
/// [DeclaredDefault] on the contract means it does not need `??` here too:
/// once declared, it is already in the request.
///
/// ```dart
/// class GreetInput implements Input {
///   final String name;
///   GreetInput({required this.name});
///
///   factory GreetInput.fromCliRequest(CliRequest req) =>
///       GreetInput(name: req.flagString('name')!);
///
///   @override
///   Map<String, dynamic> toJson() => {'name': name};
/// }
/// ```
abstract class Input {
  Input();

  /// Serialize the input payload to a JSON-encodable map.
  Map<String, dynamic> toJson();
}
