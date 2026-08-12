import 'input.dart';
import 'output.dart';

/// A unit of work that **reads and answers**, and changes nothing.
///
/// The CLI counterpart of a read in `modular_api`. There, the split between
/// reading and writing is imposed by the transport — GraphQL publishes reads,
/// REST publishes the whole use case. A CLI has one transport, so the split has
/// to be declared, and this is the declaration.
///
/// A query has no preview because it has nothing to preview, and that absence
/// is the whole difference between it and [Command]. The two share no method,
/// so neither can be mistaken for the other by accident, and the SDK rejects
/// `--plan` and `--apply` on a query without the author writing a line.
///
/// Lifecycle (managed by the framework):
///   1. Factory function builds the Query from a `CliRequest`
///   2. [validate] — return an error string, or `null` when the input is valid
///   3. [execute] — read, and return `O`
///   4. Framework formats `O` through the active output mode
///
/// ```dart
/// class ListCommands implements Query<ListInput, ListOutput> {
///   @override
///   final ListInput input;
///   ListCommands(this.input);
///
///   @override
///   String? validate() => null;
///
///   @override
///   Future<ListOutput> execute() async =>
///       ListOutput(Directory(input.path).listSync().map(basename).toList());
/// }
/// ```
abstract class Query<I extends Input, O extends Output> {
  /// The validated input for this invocation.
  I get input;

  /// Validate business rules on [input].
  /// Return a human-readable error string, or `null` when valid.
  String? validate();

  /// Read, and return the answer.
  ///
  /// Must change nothing. A unit that changes something is a [Command], and
  /// registering it as a query is how a CLI ends up with a write nobody can
  /// preview.
  Future<O> execute();
}
