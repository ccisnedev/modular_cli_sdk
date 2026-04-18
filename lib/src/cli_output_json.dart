import 'dart:convert';
import 'dart:io' as io;

import 'cli_output.dart';
import 'command_exception.dart';

/// Formats all output as JSON — one JSON value per write call.
///
/// Activated when the user passes `--json`.  Agents and scripts consume
/// this mode because every write is a self-contained JSON document on
/// stdout (or stderr for errors).
class JsonCliOutput implements CliOutput {
  JsonCliOutput({
    required this.stdout,
    required this.stderr,
    this.isQuiet = false,
  });

  final io.IOSink stdout;
  final io.IOSink stderr;
  final bool isQuiet;

  static const _encoder = JsonEncoder.withIndent('  ');

  @override
  void writeObject(Map<String, dynamic> object, {String? textOverride}) {
    // JSON mode ignores textOverride — always serialize the full object.
    stdout.writeln(_encoder.convert(object));
  }

  @override
  void writeTable(List<Map<String, dynamic>> rows, {List<String>? columns}) {
    if (columns != null) {
      final filtered = rows.map((row) {
        return {for (final col in columns) col: row[col]};
      }).toList();
      stdout.writeln(_encoder.convert(filtered));
    } else {
      stdout.writeln(_encoder.convert(rows));
    }
  }

  /// Messages are suppressed in JSON mode when `--quiet` is active.
  /// When not quiet, messages are written as `{"message": "..."}`.
  @override
  void writeMessage(String message) {
    if (isQuiet) return;
    stdout.writeln(_encoder.convert({'message': message}));
  }

  @override
  void writeError(CommandException error) {
    stderr.writeln(_encoder.convert(error.toJson()));
  }
}
