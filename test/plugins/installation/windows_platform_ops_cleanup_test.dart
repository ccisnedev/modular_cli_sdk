@TestOn('windows')
library;

/// `WindowsPlatformOps.scheduleDeletion` against real directories and a
/// real, locked file (issue #40, defect 2).
///
/// The previous cleanup script waited `timeout /t 2` once, then deleted:
///
/// ```
/// @echo off
/// timeout /t 2 /nobreak >nul
/// rmdir /s /q "$dir"
/// del "%~f0"
/// ```
///
/// If the executable is still locked after 2 s (a slow exit, antivirus, an
/// indexer), that single attempt fails, the script exits anyway (it never
/// retries), and the install directory is left behind. docmd's own
/// pre-InstallationPlugin cleanup script (a PowerShell equivalent) retried
/// up to 40 times, 250 ms apart, about 10 s total, stopping as soon as the
/// delete succeeded; this pins that same budget for the SDK's cmd.exe
/// script.
///
/// A real, separate process (PowerShell, opened with `FileShare::None`)
/// holds a file inside the install directory locked for longer than the old
/// 2 s budget but well inside the new ~10 s one, so the retry behavior is
/// observed against real Windows file-locking semantics, not a mock.
///
/// `currentExecutable` is injected (mirroring
/// `ReplaceInstallation.runningExecutable`, see installation_plugin.dart)
/// so this never touches `Platform.resolvedExecutable`, which under `dart
/// test` is the Dart VM actually running the suite.
import 'dart:convert';
import 'dart:io';

import 'package:modular_cli_sdk/modular_cli_sdk.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

Future<void> _waitUntilGone(
  FileSystemEntity entity, {
  Duration timeout = const Duration(seconds: 15),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (!entity.existsSync()) return;
    await Future<void>.delayed(const Duration(milliseconds: 150));
  }
  throw TestFailure(
    '${entity.path} still exists after waiting $timeout for it to be '
    'deleted',
  );
}

void main() {
  late Directory tempRoot;

  setUp(() {
    tempRoot = Directory.systemTemp.createTempSync('mcs_win_cleanup_test_');
  });

  tearDown(() {
    if (tempRoot.existsSync()) {
      try {
        tempRoot.deleteSync(recursive: true);
      } on FileSystemException {
        // Best effort: a test that intentionally left a file locked may
        // still have it locked for a moment after the test body returns.
      }
    }
  });

  WindowsPlatformOps ops({required String currentExecutable}) =>
      WindowsPlatformOps(
        binaryName: 'cx.exe',
        assetName: 'cx-windows.zip',
        currentExecutable: currentExecutable,
      );

  /// Holds an exclusive (no-share) handle on [file] for [lockMs] in a
  /// separate PowerShell process. The locker prints `locked` only once the
  /// handle is open, and this waits for that line, so a deletion started
  /// afterwards is guaranteed to meet a file that is really locked.
  Future<Process> lockFile(File file, int lockMs) async {
    final locker = await Process.start('powershell', [
      '-NoProfile',
      '-Command',
      '\$fs = [System.IO.File]::Open('
          "'${file.path}', 'Open', 'Read', 'None'"
          '); '
          "Write-Output 'locked'; "
          'Start-Sleep -Milliseconds $lockMs; '
          r'$fs.Close()',
    ]);
    final lines = locker.stdout
        .transform(const SystemEncoding().decoder)
        .transform(const LineSplitter());
    await lines.firstWhere((line) => line.trim() == 'locked');
    expect(
      () => file.openSync(mode: FileMode.append).closeSync(),
      throwsA(isA<FileSystemException>()),
      reason: 'the locker must really hold the file before deletion starts',
    );
    return locker;
  }

  test('retries past the old 2 s budget and still deletes once the lock '
      'clears', () async {
    final installDir = Directory(p.join(tempRoot.path, 'install'))
      ..createSync(recursive: true);
    final fakeExe = File(p.join(installDir.path, 'cx.exe'))
      ..writeAsStringSync('fake');
    final lockedFile = File(p.join(installDir.path, 'locked.bin'))
      ..writeAsStringSync('locked');

    // 3 s: longer than the old script's single 2 s wait, comfortably
    // inside the ~10 s retry budget.
    final locker = await lockFile(lockedFile, 3000);

    await ops(
      currentExecutable: fakeExe.path,
    ).scheduleDeletion(installDir.path);

    await _waitUntilGone(installDir);
    expect(await locker.exitCode, 0);
  });

  // `ping -n 1 -w 250 127.0.0.1` does not wait 250 ms: `-w` is a reply
  // timeout and localhost replies at once, so 40 of them cost only process
  // startup (under 1 s from a console, 7.7 to 9.5 s measured from a
  // detached process). With the directory locked for longer than the
  // whole budget, the script must keep retrying for at least 40 x 250 ms
  // of real sleep before it gives up and deletes itself.
  test('waits a real 250 ms between attempts: a directory that stays '
      'locked keeps the script retrying for at least 10 s', () async {
    final installDir = Directory(p.join(tempRoot.path, 'install'))
      ..createSync(recursive: true);
    final fakeExe = File(p.join(installDir.path, 'cx.exe'))
      ..writeAsStringSync('fake');
    final lockedFile = File(p.join(installDir.path, 'locked.bin'))
      ..writeAsStringSync('locked');
    final script = File(
      p.join(Directory.systemTemp.path, 'cx.exe_cleanup.cmd'),
    );

    final locker = await lockFile(lockedFile, 16000);

    final clock = Stopwatch()..start();
    await ops(
      currentExecutable: fakeExe.path,
    ).scheduleDeletion(installDir.path);
    await _waitUntilGone(script, timeout: const Duration(seconds: 15));
    clock.stop();

    expect(clock.elapsed, greaterThanOrEqualTo(const Duration(seconds: 10)));
    expect(installDir.existsSync(), isTrue);
    expect(await locker.exitCode, 0);
  });

  test('the cleanup script deletes itself once it is done', () async {
    final installDir = Directory(p.join(tempRoot.path, 'install'))
      ..createSync(recursive: true);
    final fakeExe = File(p.join(installDir.path, 'cx.exe'))
      ..writeAsStringSync('fake');

    await ops(
      currentExecutable: fakeExe.path,
    ).scheduleDeletion(installDir.path);

    await _waitUntilGone(installDir);
    await _waitUntilGone(
      File(p.join(Directory.systemTemp.path, 'cx.exe_cleanup.cmd')),
    );
  });

  for (final special in [
    'has spaces',
    'has & ampersand',
    'has ^ caret',
    'has % percent',
    'has %stray% pairs',
  ]) {
    test('deletes an install path that $special', () async {
      final installDir = Directory(p.join(tempRoot.path, 'install $special'))
        ..createSync(recursive: true);
      final fakeExe = File(p.join(installDir.path, 'cx.exe'))
        ..writeAsStringSync('fake');

      await ops(
        currentExecutable: fakeExe.path,
      ).scheduleDeletion(installDir.path);

      await _waitUntilGone(installDir);
    });
  }
}
