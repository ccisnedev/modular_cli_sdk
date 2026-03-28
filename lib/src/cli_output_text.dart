import 'dart:io' as io;

import 'cli_output.dart';
import 'command_exception.dart';

/// Formats output as human-readable plain text.
///
/// Default mode when stdout is a TTY and `--json` is not passed.
/// Objects render as `key: value` lines.  Tables render as
/// space-aligned columns.
class TextCliOutput implements CliOutput {
  TextCliOutput({
    required this.stdout,
    required this.stderr,
    this.isQuiet = false,
  });

  final io.IOSink stdout;
  final io.IOSink stderr;
  final bool isQuiet;

  @override
  void writeObject(Map<String, dynamic> object) {
    for (final entry in object.entries) {
      stdout.writeln('${entry.key}: ${entry.value}');
    }
  }

  @override
  void writeTable(List<Map<String, dynamic>> rows, {List<String>? columns}) {
    if (rows.isEmpty) return;

    final cols = columns ?? rows.first.keys.toList();

    // Calculate column widths — header label or widest cell value.
    final widths = <String, int>{for (final col in cols) col: col.length};
    for (final row in rows) {
      for (final col in cols) {
        final cellLength = '${row[col] ?? ''}'.length;
        if (cellLength > widths[col]!) {
          widths[col] = cellLength;
        }
      }
    }

    // Header
    final header = cols.map((c) => c.padRight(widths[c]!)).join('  ');
    stdout.writeln(header);
    stdout.writeln(cols.map((c) => '-' * widths[c]!).join('  '));

    // Rows
    for (final row in rows) {
      final line = cols
          .map((c) => '${row[c] ?? ''}'.padRight(widths[c]!))
          .join('  ');
      stdout.writeln(line);
    }
  }

  /// Plain text messages are suppressed when `--quiet` is active.
  @override
  void writeMessage(String message) {
    if (isQuiet) return;
    stdout.writeln(message);
  }

  @override
  void writeError(CommandException error) {
    stderr.writeln('Error: ${error.message} [${error.code}]');
    if (error.isRetryable) {
      stderr.writeln('(retryable)');
    }
    if (error.details != null && error.details!.isNotEmpty) {
      for (final entry in error.details!.entries) {
        stderr.writeln('  ${entry.key}: ${entry.value}');
      }
    }
  }
}
