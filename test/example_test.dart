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

    // The example's one writing route. Everything else in it reads, so without
    // this nothing here would exercise the half of the SDK that changes things.
    group('notes write', () {
      late Directory workspace;
      late String dir;

      setUp(() {
        workspace = Directory.systemTemp.createTempSync(
          'modular_cli_sdk_example_',
        );
        dir = '${workspace.path}/notes';
      });
      tearDown(() => workspace.deleteSync(recursive: true));

      test('refuses to guess between planning and applying', () async {
        final err = _Sink();
        final code = await runExample([
          'notes',
          'write',
          'today',
          '--dir',
          dir,
        ], stderr: err);

        expect(code, 7);
        expect(err.toString(), contains('Choose --plan or --apply'));
        expect(Directory(dir).existsSync(), isFalse);
      });

      test('--plan says what it would write and writes nothing', () async {
        final out = _Sink();
        final code = await runExample([
          'notes',
          'write',
          'today',
          '--dir',
          dir,
          '--plan',
        ], stdout: out);

        expect(code, 0);
        expect(out.toString(), contains('create'));
        expect(out.toString(), contains('today.md'));
        expect(Directory(dir).existsSync(), isFalse);
      });

      test('--apply shows the same plan to the approver', () async {
        String? shown;
        await runExample(
          ['notes', 'write', 'today', '--dir', dir, '--apply'],
          stdout: _Sink(),
          approver: (plan) async {
            shown = plan;
            return false;
          },
        );

        expect(shown, contains('today.md'));
      });

      test('--apply writes nothing when approval is refused', () async {
        final code = await runExample(
          ['notes', 'write', 'today', '--dir', dir, '--apply'],
          stdout: _Sink(),
          approver: (_) async => false,
        );

        expect(code, isNot(0));
        expect(Directory(dir).existsSync(), isFalse);
      });

      test('--apply --autoapprove writes the note', () async {
        final code = await runExample([
          'notes',
          'write',
          'today',
          '--dir',
          dir,
          '--apply',
          '--autoapprove',
        ], stdout: _Sink());

        expect(code, 0);
        expect(File('$dir/today.md').existsSync(), isTrue);
      });

      test('run twice, it keeps what is there and says so', () async {
        final args = [
          'notes',
          'write',
          'today',
          '--dir',
          dir,
          '--apply',
          '--autoapprove',
        ];
        await runExample(args, stdout: _Sink());

        final out = _Sink();
        final code = await runExample(args, stdout: out);

        expect(code, 0);
        expect(out.toString(), contains('kept'));
        expect(out.toString(), isNot(contains('written')));
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
