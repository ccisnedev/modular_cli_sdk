import 'input.dart';
import 'output.dart';

/// Abstract unit of work — the CLI equivalent of `UseCase<I, O>`.
///
/// Lifecycle (managed by the framework):
///   1. Factory function builds the Command from a `CliRequest`
///   2. [validate] — return error string, or `null` if input is valid
///   3. [execute] — run business logic, return `O`
///   4. Framework serializes `O.toJson()` and formats output
///
/// ```dart
/// class GreetCommand implements Command<GreetInput, GreetOutput> {
///   @override
///   final GreetInput input;
///   GreetCommand(this.input);
///
///   @override
///   String? validate() => input.name.isEmpty ? 'name is required' : null;
///
///   @override
///   Future<GreetOutput> execute() async =>
///       GreetOutput(greeting: 'Hello, ${input.name}!');
/// }
/// ```
abstract class Command<I extends Input, O extends Output> {
  /// The validated input for this invocation.
  I get input;

  /// Validate business rules on [input].
  /// Return a human-readable error string, or `null` when valid.
  String? validate();

  /// Execute business logic and return the result.
  Future<O> execute();
}
