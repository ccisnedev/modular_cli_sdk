import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../example/example.dart' show runExample;

void main() {
  group('Example', () {
    test('should run version and return exit code 0', () async {
      final code = await runExample(['version']);
      expect(code, 0);
    });

    test('should run greetings hello and return exit code 0', () async {
      final code = await runExample(['greetings', 'hello', '--name', 'World']);
      expect(code, 0);
    });

    test('should run math add and return exit code 0', () async {
      final code = await runExample(['math', 'add', '--a', '5', '--b', '3']);
      expect(code, 0);
    });

    test('should return exit code 64 for unknown command', () async {
      final code = await runExample(['unknown', 'command']);
      expect(code, 64);
    });

    // The example had no root command, so nothing here exercised the bare
    // invocation — which is how 0.3.0 shipped hijacking it for the help.
    group('root command', () {
      test('the bare invocation runs it, not the help', () async {
        final out = _Sink();
        final code = await runExample(const [], stdout: out);

        expect(code, 0);
        expect(out.toString(), contains('modular_cli_sdk'));
        expect(
          out.toString(),
          isNot(contains('Global options')),
          reason: 'the empty invocation was hijacked by the help command',
        );
      });

      test('`help` still shows the catalog', () async {
        final out = _Sink();
        final code = await runExample(const ['help'], stdout: out);

        expect(code, 0);
        expect(out.toString(), contains('Global options'));
        expect(out.toString(), contains('math add'));
      });
    });
  });
}

/// Collects sink writes so a command's output can be asserted.
class _Sink implements IOSink {
  final StringBuffer _buffer = StringBuffer();

  @override
  void write(Object? obj) => _buffer.write(obj);

  @override
  void writeln([Object? obj = '']) => _buffer.writeln(obj);

  @override
  Encoding encoding = utf8;

  @override
  Future<void> get done => Future.value();

  @override
  Future<void> flush() async {}

  @override
  Future<void> close() async {}

  @override
  String toString() => _buffer.toString();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
