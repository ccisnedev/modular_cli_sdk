import 'command_exception.dart';

/// Contract for writing structured data to the terminal.
///
/// The framework selects the concrete implementation based on `--json` flag
/// and TTY detection:
/// - TTY + no flags  →  [TextCliOutput]
/// - `--json`        →  [JsonCliOutput]
///
/// Commands never write to stdout directly — they return [Output] objects
/// and the framework delegates formatting to the active [CliOutput].
abstract class CliOutput {
  /// Write a single object (key-value payload).
  ///
  /// If [textOverride] is non-null and this is a text-mode output,
  /// use it directly instead of formatting the [object] map.
  void writeObject(Map<String, dynamic> object, {String? textOverride});

  /// Write a list of homogeneous objects (tabular data).
  void writeTable(List<Map<String, dynamic>> rows, {List<String>? columns});

  /// Write a plain informational message.
  void writeMessage(String message);

  /// Write a structured error to the error sink.
  void writeError(CommandException error);
}
