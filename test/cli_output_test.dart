import 'dart:convert';
import 'dart:io';

import 'package:modular_cli_sdk/modular_cli_sdk.dart';
import 'package:modular_cli_sdk/src/invocation_outcome.dart';
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
  String id = 'test-error',
  String message = 'Something failed',
  int exitCode = ExitCode.genericError,
  Map<String, dynamic>? details,
}) {
  return CommandException(
    id: id,
    message: message,
    exitCode: exitCode,
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

    test('should record error for later JSON rendering instead of writing it', () async {
      // JsonCliOutput.writeError no longer writes anything itself: it only
      // records the error into the current invocation's own outcome, which
      // ModularCli.run alone renders, exactly once, after the whole
      // dispatch finishes (round-6 review findings 1 through 3).
      await runWithInvocationOutcome(() async {
        buildOutput().writeError(_sampleError());

        final outcome = currentInvocationOutcome();
        expect(outcome.error?.id, 'test-error');
        expect(outcome.error?.message, 'Something failed');
        expect(outcome.jsonMode, isTrue);
      });
      expect(stderrSink.output, isEmpty);
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

    test('should record error for later text rendering instead of writing it', () async {
      // TextCliOutput.writeError no longer writes anything itself either:
      // same reasoning as JsonCliOutput's own test above.
      await runWithInvocationOutcome(() async {
        buildOutput().writeError(_sampleError());

        final outcome = currentInvocationOutcome();
        expect(outcome.error?.id, 'test-error');
        expect(outcome.error?.message, 'Something failed');
        expect(outcome.jsonMode, isFalse);
      });
      expect(stderrSink.output, isEmpty);
    });

    test('should write message as plain text', () {
      buildOutput().writeMessage('Done.');
      expect(stdoutSink.output.trim(), 'Done.');
    });

    test('should suppress messages when quiet is true', () {
      buildOutput(isQuiet: true).writeMessage('silent');
      expect(stdoutSink.output, isEmpty);
    });

    test('should record details alongside the error', () async {
      await runWithInvocationOutcome(() async {
        buildOutput().writeError(
          _sampleError(details: {'field': 'name', 'reason': 'required'}),
        );

        final outcome = currentInvocationOutcome();
        expect(outcome.error?.details, {'field': 'name', 'reason': 'required'});
      });
      expect(stderrSink.output, isEmpty);
    });

    test('should use textOverride when provided', () {
      buildOutput().writeObject({'key': 'value'}, textOverride: 'CUSTOM TEXT');
      expect(stdoutSink.output.trim(), equals('CUSTOM TEXT'));
    });

    test('should iterate toJson when textOverride is null', () {
      buildOutput().writeObject({'key': 'value'}, textOverride: null);
      expect(stdoutSink.output, contains('key: value'));
    });
  });
}
