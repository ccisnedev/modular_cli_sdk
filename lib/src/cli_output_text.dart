import 'dart:io' as io;

import 'cli_output.dart';
import 'command_exception.dart';
import 'invocation_outcome.dart';

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
  void writeObject(Map<String, dynamic> object, {String? textOverride}) {
    if (textOverride != null) {
      stdout.writeln(textOverride);
      return;
    }
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

  /// Records [error] as the current invocation's outcome instead of
  /// writing it: [ModularCli.run] is the only place that ever renders it,
  /// exactly once, after the whole dispatch finishes (round-6 review
  /// findings 1 through 3). [stderr] is still declared above for callers
  /// that read it as this output's own error sink, but this method itself
  /// no longer writes to it directly.
  @override
  void writeError(CommandException error) {
    recordInvocationError(error, jsonMode: false);
  }
}
