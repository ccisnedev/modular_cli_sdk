/// The cleanup worker's bootstrap script content, and (Windows-only) the
/// real worker's behaviour against a real process and a real file: it
/// deletes nothing while the parent it was told to watch is still alive,
/// and deletes the given path once that parent exits, including when the
/// process that launched it has itself already exited, which is the whole
/// point of a cleanup worker.
library;

import 'dart:io' as io;

import 'package:modular_cli_sdk/modular_cli_sdk.dart';
import 'package:test/test.dart';

void main() {
  group('cleanupWorkerBootstrapScript', () {
    // Fixed and never interpolated: every piece of run-specific data is
    // read once from a JSON payload file instead, so nothing here needs to
    // escape a path, and nothing here is built from a command-line
    // argument that a shell could re-parse.
    test('reads its payload from a file named by an environment variable', () {
      expect(cleanupWorkerBootstrapScript, contains('ConvertFrom-Json'));
      expect(cleanupWorkerBootstrapScript, contains('Get-Content'));
      expect(
        cleanupWorkerBootstrapScript,
        contains(r'$env:' + cleanupWorkerPayloadPathEnvVar),
      );
    });

    test(
      'signals readiness through a marker file named by an environment '
      'variable',
      () {
        expect(
          cleanupWorkerBootstrapScript,
          contains(r'$env:' + cleanupWorkerReadyMarkerPathEnvVar),
        );
        expect(cleanupWorkerBootstrapScript, contains('New-Item'));
      },
    );

    test('retains a handle on the parent process before signalling ready', () {
      expect(cleanupWorkerBootstrapScript, contains('GetProcessById'));
      expect(cleanupWorkerBootstrapScript, contains(r'$parent.Handle'));
      final newItemIndex = cleanupWorkerBootstrapScript.indexOf('New-Item');
      final handleIndex = cleanupWorkerBootstrapScript.indexOf(
        r'$parent.Handle',
      );
      expect(handleIndex, greaterThanOrEqualTo(0));
      expect(newItemIndex, greaterThan(handleIndex));
    });

    test('waits for the parent to exit before deleting anything', () {
      expect(cleanupWorkerBootstrapScript, contains('WaitForExit'));
      final waitIndex = cleanupWorkerBootstrapScript.indexOf('WaitForExit');
      final removeTargetIndex = cleanupWorkerBootstrapScript.indexOf(
        r'Remove-Item -LiteralPath $path',
      );
      expect(removeTargetIndex, greaterThan(waitIndex));
    });

    test('deletes with -LiteralPath under a Stop error action', () {
      expect(
        cleanupWorkerBootstrapScript,
        contains("\$ErrorActionPreference = 'Stop'"),
      );
      expect(
        cleanupWorkerBootstrapScript,
        contains('Remove-Item -LiteralPath'),
      );
    });

    test('cleans up its own payload and ready-marker files', () {
      expect(
        cleanupWorkerBootstrapScript,
        contains(r'Remove-Item -LiteralPath $PayloadPath'),
      );
      expect(
        cleanupWorkerBootstrapScript,
        contains(r'Remove-Item -LiteralPath $ReadyMarkerPath'),
      );
    });
  });

  group('powershellExecutablePath', () {
    test('resolves the fixed path under SystemRoot', () {
      expect(
        powershellExecutablePath({'SystemRoot': r'C:\Windows'}),
        r'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe',
      );
    });

    test('throws CliCleanupWorkerStartFailure when SystemRoot is absent', () {
      expect(
        () => powershellExecutablePath({}),
        throwsA(isA<CliCleanupWorkerStartFailure>()),
      );
    });

    test('throws CliCleanupWorkerStartFailure when SystemRoot is empty', () {
      expect(
        () => powershellExecutablePath({'SystemRoot': ''}),
        throwsA(isA<CliCleanupWorkerStartFailure>()),
      );
    });
  });

  group('cmdExecutablePath', () {
    test('resolves the fixed path under SystemRoot', () {
      expect(
        cmdExecutablePath({'SystemRoot': r'C:\Windows'}),
        r'C:\Windows\System32\cmd.exe',
      );
    });

    test('throws CliCleanupWorkerStartFailure when SystemRoot is absent', () {
      expect(
        () => cmdExecutablePath({}),
        throwsA(isA<CliCleanupWorkerStartFailure>()),
      );
    });

    test('throws CliCleanupWorkerStartFailure when SystemRoot is empty', () {
      expect(
        () => cmdExecutablePath({'SystemRoot': ''}),
        throwsA(isA<CliCleanupWorkerStartFailure>()),
      );
    });
  });

  group('IoCliProcessLauncher.startCleanupWorker', () {
    test(
      'deletes the given path once the parent process it was told to '
      'watch exits, and not before',
      () async {
        final tempDir = io.Directory.systemTemp.createTempSync(
          'cleanup_worker_test_',
        );
        addTearDown(() {
          if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
        });
        final targetPath =
            '${tempDir.path}${io.Platform.pathSeparator}victim.txt';
        io.File(targetPath).writeAsStringSync('gone soon');

        final parent = await io.Process.start('powershell', [
          '-NoProfile',
          '-NonInteractive',
          '-Command',
          'Start-Sleep -Seconds 60',
        ]);

        try {
          const launcher = IoCliProcessLauncher();
          await launcher.startCleanupWorker({
            'parentPid': parent.pid,
            'paths': [targetPath],
            'timeoutMs': 60000,
          });

          // The worker has signalled ready, but the parent it is waiting on
          // is still alive: nothing has been deleted yet.
          await Future<void>.delayed(const Duration(seconds: 1));
          expect(io.File(targetPath).existsSync(), isTrue);

          parent.kill();
          await parent.exitCode;

          final deadline = DateTime.now().add(const Duration(seconds: 20));
          while (io.File(targetPath).existsSync() &&
              DateTime.now().isBefore(deadline)) {
            await Future<void>.delayed(const Duration(milliseconds: 200));
          }
          expect(io.File(targetPath).existsSync(), isFalse);
        } finally {
          try {
            parent.kill();
          } on Object {
            // Already gone; nothing left to clean up.
          }
        }
      },
      skip: io.Platform.isWindows
          ? false
          : 'launches a real Windows PowerShell cleanup worker',
      timeout: const Timeout(Duration(seconds: 40)),
    );

    test(
      'the worker survives even when the process that launched it exits '
      'immediately afterwards, the way a real CLI run does',
      () async {
        final tempDir = io.Directory.systemTemp.createTempSync(
          'cleanup_worker_survival_test_',
        );
        addTearDown(() {
          if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
        });
        // Tricky characters the payload JSON file must carry through
        // untouched: no shell (cmd.exe's or PowerShell's) ever parses this
        // path, only Get-Content/ConvertFrom-Json does.
        const trickyName = "victim that's (weird) 100% & loud!.txt";
        final targetPath =
            '${tempDir.path}${io.Platform.pathSeparator}$trickyName';
        io.File(targetPath).writeAsStringSync('gone soon');

        // `dart run` resolves the package config by walking up from the
        // script's own location, not from the working directory it is
        // launched with: the helper has to live inside this package, not
        // in a system temp directory outside it.
        final helperScript = io.File(
          'test/plugins/installation/.cleanup_worker_survival_helper.dart',
        )..writeAsStringSync('''
import 'package:modular_cli_sdk/modular_cli_sdk.dart';

Future<void> main(List<String> args) async {
  const launcher = IoCliProcessLauncher();
  await launcher.startCleanupWorker({
    'parentPid': launcher.currentPid,
    'paths': [args[0]],
    'timeoutMs': 15000,
  });
}
''');
        addTearDown(() {
          if (helperScript.existsSync()) helperScript.deleteSync();
        });

        final result = await io.Process.run(
          io.Platform.resolvedExecutable,
          ['run', helperScript.path, targetPath],
          workingDirectory: io.Directory.current.path,
        );
        expect(
          result.exitCode,
          0,
          reason:
              'the helper process must confirm the worker is ready before '
              'it exits: ${result.stdout}\n${result.stderr}',
        );

        // The helper process (the "CLI") has already fully exited by now:
        // this is exactly the scenario ProcessStartMode.normal cannot
        // survive, because Windows kills a normal child's whole job when
        // its launcher exits.
        final deadline = DateTime.now().add(const Duration(seconds: 20));
        while (io.File(targetPath).existsSync() &&
            DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }
        expect(io.File(targetPath).existsSync(), isFalse);
      },
      skip: io.Platform.isWindows
          ? false
          : 'launches a real Windows PowerShell cleanup worker',
      timeout: const Timeout(Duration(seconds: 40)),
    );
  });
}
