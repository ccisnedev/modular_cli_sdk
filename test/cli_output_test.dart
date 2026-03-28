import 'dart:convert';
import 'dart:io';

import 'package:modular_cli_sdk/modular_cli_sdk.dart';
import 'package:test/test.dart';

// ── Helpers ─────────────────────────────────────────────────────────────────

/// In-memory IOSink that captures written bytes as a string.
class _MemorySink implements IOSink {
  final StringBuffer _buffer = StringBuffer();

  String get output => _buffer.toString();

  @override
  void write(Object? object) => _buffer.write(object);
  @override
  void writeln([Object? object = '']) {
    _buffer.write(object);
    _buffer.write('\n');
  }

  @override
  void writeAll(Iterable objects, [String separator = '']) {
    _buffer.writeAll(objects, separator);
  }

  @override
  void writeCharCode(int charCode) => _buffer.writeCharCode(charCode);
  @override
  void add(List<int> data) => _buffer.write(utf8.decode(data));
  @override
  void addError(Object error, [StackTrace? stackTrace]) {}
  @override
  Future addStream(Stream<List<int>> stream) async {
    await for (final data in stream) {
      add(data);
    }
  }

  @override
  Future flush() async {}
  @override
  Future close() async {}
  @override
  Future get done => Future.value();
  @override
  Encoding encoding = utf8;
}

CommandException _sampleError({
  String code = 'TEST_ERROR',
  String message = 'Something failed',
  int exitCode = ExitCode.genericError,
  bool isRetryable = false,
  Map<String, dynamic>? details,
}) {
  return CommandException(
    code: code,
    message: message,
    exitCode: exitCode,
    isRetryable: isRetryable,
    details: details,
  );
}

// ── Tests ───────────────────────────────────────────────────────────────────

void main() {
  group('JsonCliOutput', () {
    late _MemorySink stdoutSink;
    late _MemorySink stderrSink;

    setUp(() {
      stdoutSink = _MemorySink();
      stderrSink = _MemorySink();
    });

    JsonCliOutput buildOutput({bool isQuiet = false}) =>
        JsonCliOutput(stdout: stdoutSink, stderr: stderrSink, isQuiet: isQuiet);

    test('should write object as JSON to sink', () {
      buildOutput().writeObject({'name': 'Alice', 'age': 30});

      final parsed = jsonDecode(stdoutSink.output);
      expect(parsed, {'name': 'Alice', 'age': 30});
    });

    test('should write table as JSON array to sink', () {
      buildOutput().writeTable([
        {'id': 1, 'name': 'A'},
        {'id': 2, 'name': 'B'},
      ]);

      final parsed = jsonDecode(stdoutSink.output) as List;
      expect(parsed.length, 2);
      expect(parsed[0]['name'], 'A');
    });

    test('should write table with column filter', () {
      buildOutput().writeTable(
        [
          {'id': 1, 'name': 'A', 'hidden': 'x'},
          {'id': 2, 'name': 'B', 'hidden': 'y'},
        ],
        columns: ['id', 'name'],
      );

      final parsed = jsonDecode(stdoutSink.output) as List;
      expect((parsed[0] as Map).containsKey('hidden'), isFalse);
    });

    test('should write error as JSON to stderr', () {
      buildOutput().writeError(_sampleError());

      final parsed = jsonDecode(stderrSink.output);
      expect(parsed['error'], 'TEST_ERROR');
      expect(parsed['message'], 'Something failed');
    });

    test('should suppress messages when quiet is true', () {
      buildOutput(isQuiet: true).writeMessage('hello');
      expect(stdoutSink.output, isEmpty);
    });

    test('should write messages as JSON when not quiet', () {
      buildOutput().writeMessage('hello');
      final parsed = jsonDecode(stdoutSink.output);
      expect(parsed['message'], 'hello');
    });
  });

  group('TextCliOutput', () {
    late _MemorySink stdoutSink;
    late _MemorySink stderrSink;

    setUp(() {
      stdoutSink = _MemorySink();
      stderrSink = _MemorySink();
    });

    TextCliOutput buildOutput({bool isQuiet = false}) =>
        TextCliOutput(stdout: stdoutSink, stderr: stderrSink, isQuiet: isQuiet);

    test('should write object as key: value pairs to sink', () {
      buildOutput().writeObject({'name': 'Alice', 'age': 30});

      expect(stdoutSink.output, contains('name: Alice'));
      expect(stdoutSink.output, contains('age: 30'));
    });

    test('should write table as aligned columns to sink', () {
      buildOutput().writeTable([
        {'id': '1', 'name': 'Alice'},
        {'id': '2', 'name': 'Bob'},
      ]);

      final lines = stdoutSink.output.split('\n');
      // Header + separator + 2 rows + trailing newline
      expect(lines.length, greaterThanOrEqualTo(4));
      expect(lines[0], contains('id'));
      expect(lines[0], contains('name'));
      // Separator row
      expect(lines[1], contains('--'));
    });

    test('should write error with prefix to stderr sink', () {
      buildOutput().writeError(_sampleError());
      expect(stderrSink.output, contains('Error:'));
      expect(stderrSink.output, contains('Something failed'));
      expect(stderrSink.output, contains('TEST_ERROR'));
    });

    test('should write message as plain text', () {
      buildOutput().writeMessage('Done.');
      expect(stdoutSink.output.trim(), 'Done.');
    });

    test('should suppress messages when quiet is true', () {
      buildOutput(isQuiet: true).writeMessage('silent');
      expect(stdoutSink.output, isEmpty);
    });

    test('should include retryable hint for retryable errors', () {
      buildOutput().writeError(_sampleError(isRetryable: true));
      expect(stderrSink.output, contains('retryable'));
    });

    test('should include details in error output', () {
      buildOutput().writeError(
        _sampleError(details: {'field': 'name', 'reason': 'required'}),
      );
      expect(stderrSink.output, contains('field'));
      expect(stderrSink.output, contains('required'));
    });
  });
}
