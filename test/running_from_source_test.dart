/// Pins the difference between running a CLI from source and running it as a
/// built artifact — and pins that the README tells the truth about it.
///
/// This is the only test in the suite that compiles executables. It is slow on
/// purpose: the defect it guards has no cheaper witness. Running through
/// `dart run` makes `Platform.resolvedExecutable` point at the Dart binary, so
/// anything a CLI locates beside itself is looked for inside the Dart SDK and
/// is not found. Nothing warns; the CLI answers, and answers wrongly.
///
/// Three facts are held here:
///   1. the Quick start's CLI answers the same either way — it locates nothing
///      beside its executable, so `dart run` is genuinely equivalent for it;
///   2. the second example answers differently, and the binary is the one that
///      answers correctly;
///   3. the outputs written in the README are the ones the commands produce.
library;

import 'dart:io';

import 'package:test/test.dart';

/// Compiling twice takes far longer than the default 30s, on CI most of all.
const _timeout = Timeout(Duration(minutes: 5));

void main() {
  group('Running from source', () {
    late Directory devroot;

    setUpAll(() {
      devroot = Directory.systemTemp.createTempSync('mcs_devbuild_');
    });

    tearDownAll(() {
      if (devroot.existsSync()) devroot.deleteSync(recursive: true);
    });

    test(
      'the Quick start CLI answers the same from source and as a binary',
      () async {
        final fromSource = await _dartRun('example/example.dart', ['version']);
        final binary = await _compile('example/example.dart', devroot, 'example');
        final fromBinary = await _run(binary, ['version']);

        expect(fromSource.exitCode, 0, reason: fromSource.stderr);
        expect(fromBinary.exitCode, 0, reason: fromBinary.stderr);
        expect(
          fromBinary.stdout,
          fromSource.stdout,
          reason: 'this CLI locates nothing beside its executable, so the two '
              'ways of running it must not diverge',
        );
      },
      timeout: _timeout,
    );

    test(
      'the second example answers differently, and the binary is right',
      () async {
        final binary = await _compile(
          'example/beside_executable.dart',
          devroot,
          'beside_executable',
        );
        _installAsset(devroot);

        final fromSource = await _dartRun('example/beside_executable.dart', [
          'greet',
        ]);
        final fromBinary = await _run(binary, ['greet']);

        expect(
          fromBinary.exitCode,
          0,
          reason: 'the binary has its assets beside it: ${fromBinary.stderr}',
        );
        expect(fromBinary.stdout, contains('Hello from the assets folder'));

        expect(
          fromSource.exitCode,
          isNot(0),
          reason: 'under `dart run` the asset is looked for beside the Dart '
              'binary, so it cannot be found — and the CLI must say so rather '
              'than answer anyway',
        );
        expect(
          fromBinary.stdout,
          isNot(fromSource.stdout),
          reason: 'if these ever agree, the example has stopped demonstrating '
              'the thing the README documents',
        );
      },
      timeout: _timeout,
    );

    test(
      'the outputs the README shows are the ones the commands produce',
      () async {
        final readme = File('README.md').readAsStringSync();

        final binary = await _compile(
          'example/beside_executable.dart',
          devroot,
          'beside_executable',
        );
        _installAsset(devroot);

        final fromBinary = await _run(binary, ['greet']);
        final fromSource = await _dartRun('example/beside_executable.dart', [
          'greet',
        ]);

        for (final shown in [fromBinary.stdout, fromSource.stderr]) {
          final line = shown.trim().split('\n').first.trim();
          expect(
            readme,
            contains(line),
            reason: 'the README shows an output this command does not produce. '
                'Never retype an output — paste the real one.',
          );
        }
      },
      timeout: _timeout,
    );
  });
}

// ── Helpers ─────────────────────────────────────────────────────────────────

class _Result {
  final int exitCode;
  final String stdout;
  final String stderr;
  _Result(this.exitCode, this.stdout, this.stderr);
}

Future<_Result> _dartRun(String script, List<String> args) async {
  final r = await Process.run(Platform.resolvedExecutable, [
    'run',
    script,
    ...args,
  ], workingDirectory: Directory.current.path);
  return _Result(r.exitCode, r.stdout.toString(), r.stderr.toString());
}

Future<_Result> _run(File binary, List<String> args) async {
  final r = await Process.run(binary.path, args);
  return _Result(r.exitCode, r.stdout.toString(), r.stderr.toString());
}

/// Compiles [script] into `<devroot>/bin/<name>` — the layout the README
/// teaches, and the one an installed CLI has: the binary in `bin/`, with
/// `assets/` beside it one level up.
Future<File> _compile(String script, Directory devroot, String name) async {
  final bin = Directory('${devroot.path}/bin')..createSync(recursive: true);
  final out = '${bin.path}/$name';
  final r = await Process.run(Platform.resolvedExecutable, [
    'compile',
    'exe',
    script,
    '-o',
    out,
  ]);
  if (r.exitCode != 0) {
    fail('dart compile exe failed for $script:\n${r.stdout}\n${r.stderr}');
  }
  return File(out);
}

/// Puts the asset where the *installed* CLI would have it: `<devroot>/assets/`,
/// beside `bin/` rather than inside it.
void _installAsset(Directory devroot) {
  final assets = Directory('${devroot.path}/assets')
    ..createSync(recursive: true);
  File('${assets.path}/greeting.txt')
      .writeAsStringSync('Hello from the assets folder\n');
}
