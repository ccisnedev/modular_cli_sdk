/// The cleanup worker's bootstrap script content, and (Windows-only) the
/// real worker's behaviour against a real process and a real file: it
/// deletes nothing while the parent it was told to watch is still alive,
/// and deletes the given path once that parent exits, including when the
/// process that launched it has itself already exited, which is the whole
/// point of a cleanup worker. Also covers the command-line-injection,
/// non-ASCII-payload, predictable-temp-name and leftover-artifact findings:
/// no path ever appears on the `cmd.exe` command line, the payload travels
/// as an environment variable rather than a file a pre-BOM-unaware
/// `Get-Content` could misread, the ready marker lives inside a privately
/// and exclusively created temporary directory, and the launcher removes
/// that directory on every outcome.
library;

import 'dart:convert';
import 'dart:io' as io;

import 'package:modular_cli_sdk/modular_cli_sdk.dart';
import 'package:test/test.dart';

/// Every directory directly under the system temp directory whose name
/// starts with the private-directory prefix [IoCliProcessLauncher] uses for
/// the cleanup worker's ready marker. Used to assert nothing is left behind,
/// on both a successful run and a startup failure.
Set<String> _existingCleanupPrivateDirs() => io.Directory.systemTemp
    .listSync()
    .whereType<io.Directory>()
    .map((d) => d.path)
    .where((path) => path.split(io.Platform.pathSeparator).last.startsWith(
          'cli_cleanup_',
        ))
    .toSet();

void main() {
  group('cleanupWorkerBootstrapScript', () {
    // Fixed and never interpolated: every piece of run-specific data is
    // read once from a JSON payload carried by an environment variable
    // instead, so nothing here needs to escape a path, and nothing here is
    // built from a command-line argument that a shell could re-parse.
    test('reads its payload from an environment variable, not a file', () {
      expect(cleanupWorkerBootstrapScript, contains('ConvertFrom-Json'));
      expect(
        cleanupWorkerBootstrapScript,
        contains(r'$env:' + cleanupWorkerPayloadEnvVar),
      );
      // No file read: an environment variable is inherited by the child
      // through Windows' native, Unicode-safe environment block, never
      // through a UTF-8-without-BOM file a PowerShell 5.1 Get-Content call
      // would decode as the system ANSI code page and silently corrupt.
      expect(cleanupWorkerBootstrapScript, isNot(contains('Get-Content')));
    });

    test(
      'signals readiness through a marker file named by an environment '
      'variable, created without recreating a missing parent directory',
      () {
        expect(
          cleanupWorkerBootstrapScript,
          contains(r'$env:' + cleanupWorkerReadyMarkerPathEnvVar),
        );
        // Round 5 finding 2: New-Item -Force recreates a private directory
        // the CLI already deleted after giving up waiting, letting a late
        // worker silently schedule a deletion the CLI already reported as
        // failed. File.Open with CreateNew fails instead, both when the
        // directory is gone and when the marker somehow already exists.
        expect(
          cleanupWorkerBootstrapScript,
          contains('[System.IO.FileMode]::CreateNew'),
        );
        expect(cleanupWorkerBootstrapScript, isNot(contains('New-Item')));
        expect(cleanupWorkerBootstrapScript, isNot(contains('-Force')));
      },
    );

    test('retains a handle on the parent process before signalling ready', () {
      expect(cleanupWorkerBootstrapScript, contains('GetProcessById'));
      expect(cleanupWorkerBootstrapScript, contains(r'$parent.Handle'));
      final markerIndex = cleanupWorkerBootstrapScript.indexOf(
        '[System.IO.FileMode]::CreateNew',
      );
      final handleIndex = cleanupWorkerBootstrapScript.indexOf(
        r'$parent.Handle',
      );
      expect(handleIndex, greaterThanOrEqualTo(0));
      expect(markerIndex, greaterThan(handleIndex));
    });

    // Round 5 finding 1: GetProcessById throwing System.ArgumentException
    // means no such process exists, which is genuinely "the parent already
    // exited" and safe to treat as $parent = $null. Any other failure
    // retaining a handle on a process that does exist (most notably,
    // access denied on .Handle itself for a protected process) must not be
    // folded into that same "already exited" outcome: it has to stop the
    // worker before the ready marker is created, so the CLI sees no marker
    // in time and reports cleanup-start-failed instead of a worker that
    // silently is not actually holding what it needs.
    test(
      'catches only ArgumentException around GetProcessById, so a '
      'different failure retaining the handle is not folded into '
      '"parent already exited"',
      () {
        expect(
          cleanupWorkerBootstrapScript,
          contains('catch [System.ArgumentException]'),
        );
        final catchIndex = cleanupWorkerBootstrapScript.indexOf(
          'catch [System.ArgumentException]',
        );
        final handleIndex = cleanupWorkerBootstrapScript.indexOf(
          r'$parent.Handle',
        );
        expect(catchIndex, greaterThanOrEqualTo(0));
        expect(handleIndex, greaterThanOrEqualTo(0));
        // The handle access sits after the typed catch block closes, not
        // inside a try that would catch a Win32Exception from it too.
        expect(handleIndex, greaterThan(catchIndex));
      },
    );

    // Round 5 finding 2: closes the race where startCleanupWorker has
    // already given up waiting for a marker and deleted the private
    // directory it created. Past this deadline (computed by the CLI from
    // its own startup timeout and safety margin, carried in the payload)
    // the worker refuses to create the marker and exits, deleting nothing,
    // rather than silently scheduling a deletion the CLI already reported
    // as failed.
    test(
      'refuses to create the marker past a deadline read from the payload',
      () {
        expect(cleanupWorkerBootstrapScript, contains('markerDeadlineUnixMs'));
        expect(
          cleanupWorkerBootstrapScript,
          contains('ToUnixTimeMilliseconds'),
        );
        final deadlineCheckIndex = cleanupWorkerBootstrapScript.indexOf(
          'markerDeadlineUnixMs',
        );
        final markerIndex = cleanupWorkerBootstrapScript.indexOf(
          '[System.IO.FileMode]::CreateNew',
        );
        expect(deadlineCheckIndex, greaterThanOrEqualTo(0));
        expect(markerIndex, greaterThan(deadlineCheckIndex));
      },
    );

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
  });

  group('cleanupWorkerEncodedBootstrapScript', () {
    test('is the fixed bootstrap script Base64-encoded as UTF-16LE', () {
      final decoded = String.fromCharCodes(
        _decodeUtf16Le(base64.decode(cleanupWorkerEncodedBootstrapScript)),
      );
      expect(decoded, cleanupWorkerBootstrapScript);
    });
  });

  group('cleanupWorkerCmdCommandLine', () {
    test('stays well under cmd.exe\'s roughly 8191-character limit', () {
      final commandLine = cleanupWorkerCmdCommandLine(
        r'C:\Windows\System32\cmd.exe',
        r'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe',
      );
      expect(commandLine.length, lessThan(8191));
    });

    test('carries the encoded bootstrap script and the PowerShell path', () {
      final commandLine = cleanupWorkerCmdCommandLine(
        r'C:\Windows\System32\cmd.exe',
        r'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe',
      );
      expect(commandLine, contains(cleanupWorkerEncodedBootstrapScript));
      expect(
        commandLine,
        contains(r'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'),
      );
      expect(commandLine, contains('-EncodedCommand'));
      // No -File and no script path at all: there is no script file to name.
      expect(commandLine, isNot(contains('-File')));
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

    // The resolved path is the only run-specific value that ever appears on
    // the cmd.exe command line IoCliProcessLauncher builds: a SystemRoot an
    // attacker controls (or one simply misconfigured) must not be able to
    // inject an extra command or escape the intended argument.
    for (final metacharacter in const [
      '&',
      '|',
      '<',
      '>',
      '^',
      '%',
      '!',
      '"',
    ]) {
      test(
        'throws CliCleanupWorkerStartFailure when SystemRoot contains '
        '$metacharacter',
        () {
          expect(
            () => powershellExecutablePath({
              'SystemRoot': 'C:\\Windows${metacharacter}evil',
            }),
            throwsA(isA<CliCleanupWorkerStartFailure>()),
          );
        },
      );
    }
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
        // Tricky characters the payload environment variable must carry
        // through untouched: no shell (cmd.exe's or PowerShell's) ever
        // parses this path, only ConvertFrom-Json does.
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

    test(
      'a TEMP directory containing cmd.exe metacharacters and spaces does '
      'not break the launch or the eventual deletion',
      () async {
        final realTemp = io.Directory.systemTemp;
        final trickyTempDir = io.Directory(
          '${realTemp.path}${io.Platform.pathSeparator}'
          'cli_test_tricky_&%!^() dir',
        )..createSync();
        addTearDown(() {
          if (trickyTempDir.existsSync()) {
            trickyTempDir.deleteSync(recursive: true);
          }
        });

        final targetPath =
            '${trickyTempDir.path}${io.Platform.pathSeparator}victim.txt';
        io.File(targetPath).writeAsStringSync('gone soon');

        final helperScript = io.File(
          'test/plugins/installation/.cleanup_worker_tricky_temp_helper.dart',
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
          environment: {
            ...io.Platform.environment,
            'TEMP': trickyTempDir.path,
            'TMP': trickyTempDir.path,
          },
        );
        expect(
          result.exitCode,
          0,
          reason:
              'the helper process must confirm the worker is ready before '
              'it exits: ${result.stdout}\n${result.stderr}',
        );

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

    test(
      'deletes a target whose path contains non-ASCII characters',
      () async {
        final tempDir = io.Directory.systemTemp.createTempSync(
          'cleanup_worker_unicode_test_',
        );
        addTearDown(() {
          if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
        });
        final targetPath =
            '${tempDir.path}${io.Platform.pathSeparator}José.txt';
        io.File(targetPath).writeAsStringSync('gone soon');

        final helperScript = io.File(
          'test/plugins/installation/.cleanup_worker_unicode_helper.dart',
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

    test(
      'leaves no private directory behind once the worker has confirmed '
      'ready',
      () async {
        final tempDir = io.Directory.systemTemp.createTempSync(
          'cleanup_worker_artifact_test_',
        );
        addTearDown(() {
          if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
        });
        final targetPath =
            '${tempDir.path}${io.Platform.pathSeparator}victim.txt';
        io.File(targetPath).writeAsStringSync('gone soon');

        final before = _existingCleanupPrivateDirs();

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

          expect(
            _existingCleanupPrivateDirs(),
            before,
            reason:
                'the private directory created for the ready marker must be '
                'removed once startCleanupWorker has seen the worker '
                'confirm ready',
          );
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

    // Round 5 finding 1.
    test(
      'a parent process the worker cannot get a handle on (as opposed to '
      'one that does not exist) stops the worker before it creates the '
      'marker, so startCleanupWorker reports cleanup-start-failed rather '
      'than silently treating access-denied as "parent already exited"',
      () async {
        // pid 4 is the Windows kernel's own "System" process: a real,
        // always-running pid, so GetProcessById(4) itself succeeds and this
        // is not the "no such process" ArgumentException case finding 1
        // also has to tell apart. Reading .Handle on the resulting Process
        // object is what is expected to throw. If this environment's token
        // can retain a handle on it after all, the premise this test needs
        // does not hold here, and it skips with that reason rather than
        // asserting a behaviour it cannot actually provoke.
        final probe = await io.Process.run('powershell', [
          '-NoProfile',
          '-NonInteractive',
          '-Command',
          r'try { $null = ([System.Diagnostics.Process]::GetProcessById(4)).Handle; "handle-ok" } catch { "handle-denied" }',
        ]);
        if (probe.stdout.toString().trim() != 'handle-denied') {
          markTestSkipped(
            'this environment\'s token can retain a Process.Handle on pid '
            '4 (the System process), so it cannot reproduce the '
            'access-denied case this test needs: ${probe.stdout}',
          );
          return;
        }

        final before = _existingCleanupPrivateDirs();
        const launcher = IoCliProcessLauncher();

        await expectLater(
          launcher.startCleanupWorker({
            'parentPid': 4,
            'paths': <String>[],
            'timeoutMs': 1000,
          }),
          throwsA(isA<CliCleanupWorkerStartFailure>()),
        );

        expect(
          _existingCleanupPrivateDirs(),
          before,
          reason:
              'a worker stopped by an access-denied handle failure must '
              'leave no private directory behind either',
        );
      },
      skip: io.Platform.isWindows
          ? false
          : 'launches a real Windows PowerShell cleanup worker',
      timeout: const Timeout(Duration(seconds: 40)),
    );

    // Round 5 finding 2(b).
    test(
      'a worker that starts too close to the CLI giving up refuses to '
      'create the marker, or recreate the private directory, and deletes '
      'nothing',
      () async {
        final tempDir = io.Directory.systemTemp.createTempSync(
          'cleanup_worker_deadline_test_',
        );
        addTearDown(() {
          if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
        });
        final targetPath =
            '${tempDir.path}${io.Platform.pathSeparator}victim.txt';
        io.File(targetPath).writeAsStringSync('gone soon');

        final before = _existingCleanupPrivateDirs();

        // A safety margin almost as large as the startup timeout itself
        // leaves the worker only a few milliseconds, from launch, to
        // create its marker: nowhere near enough for a real powershell.exe
        // process to even finish starting, let alone parse its payload and
        // reach the marker-creation step. The CLI's own timeout is left
        // long enough (2s) for that real process to actually run to
        // completion (refusing to create the marker, and so deleting
        // nothing) before this test moves on to asserting that.
        final launcher = IoCliProcessLauncher(
          startupTimeout: const Duration(seconds: 2),
          markerDeadlineSafetyMargin: const Duration(milliseconds: 1990),
        );

        await expectLater(
          launcher.startCleanupWorker({
            'parentPid': io.pid,
            'paths': [targetPath],
            'timeoutMs': 60000,
          }),
          throwsA(isA<CliCleanupWorkerStartFailure>()),
        );

        // Gives the real, still-running worker time to reach its own
        // deadline check and exit, so a bug that let it through would
        // already have shown itself by the time the assertions below run.
        await Future<void>.delayed(const Duration(seconds: 3));

        expect(
          io.File(targetPath).existsSync(),
          isTrue,
          reason:
              'a worker that started past its own deadline must delete '
              'nothing',
        );
        expect(
          _existingCleanupPrivateDirs(),
          before,
          reason:
              'a worker that started past its own deadline must not '
              'recreate the private directory the CLI already gave up on',
        );
      },
      skip: io.Platform.isWindows
          ? false
          : 'launches a real Windows PowerShell cleanup worker',
      timeout: const Timeout(Duration(seconds: 40)),
    );

    // Round 5 finding 4: the two tests below use _FailingCleanupDirectory
    // Launcher's deletePrivateDirectory seam to provoke a real private
    // directory cleanup failure deterministically, since nothing portable
    // lets a test make a real deleteSync fail at exactly this point
    // otherwise.
    test(
      'returns a warning naming the private directory and the error when '
      'cleanup of it fails after the worker confirms ready',
      () async {
        final tempDir = io.Directory.systemTemp.createTempSync(
          'cleanup_worker_dir_warning_test_',
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
          final launcher = _FailingCleanupDirectoryLauncher(
            Exception('directory busy'),
          );
          final warning = await launcher.startCleanupWorker({
            'parentPid': parent.pid,
            'paths': [targetPath],
            'timeoutMs': 60000,
          });

          expect(warning, isNotNull);
          expect(warning, contains('directory busy'));
          expect(warning, contains('cli_cleanup_'));

          // The primary outcome (the worker did confirm ready) is still
          // what happened: the target still exists only because the
          // parent process above is still alive, not because anything
          // failed to schedule.
          expect(io.File(targetPath).existsSync(), isTrue);
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
      'a launch failure names a cleanup-directory failure in its own '
      'message when both fail',
      () async {
        final launcher = _FailingCleanupDirectoryLauncher(
          Exception('directory busy'),
          startupTimeout: const Duration(milliseconds: 500),
        );

        await expectLater(
          launcher.startCleanupWorker({
            // Not an integer: the worker's $ErrorActionPreference = 'Stop'
            // makes [int]$data.parentPid throw before it ever creates its
            // ready-marker file, so this never confirms ready and
            // startCleanupWorker times out waiting for it, the primary
            // failure this test's cleanup-directory failure must be
            // attached to rather than replace.
            'parentPid': 'not-a-pid',
            'paths': <String>[],
            'timeoutMs': 1000,
          }),
          throwsA(
            isA<CliCleanupWorkerStartFailure>()
                .having(
                  (e) => e.message,
                  'message',
                  contains('did not confirm it was ready'),
                )
                .having(
                  (e) => e.message,
                  'message',
                  contains('directory busy'),
                ),
          ),
        );
      },
      skip: io.Platform.isWindows
          ? false
          : 'launches a real Windows PowerShell cleanup worker',
      timeout: const Timeout(Duration(seconds: 40)),
    );

    test(
      'leaves no private directory behind when the worker never confirms '
      'ready',
      () async {
        final before = _existingCleanupPrivateDirs();

        const launcher = IoCliProcessLauncher();
        await expectLater(
          launcher.startCleanupWorker({
            // Not an integer: the worker's $ErrorActionPreference = 'Stop'
            // makes [int]$data.parentPid throw before it ever creates its
            // ready-marker file, so this never confirms ready and
            // startCleanupWorker times out waiting for it.
            'parentPid': 'not-a-pid',
            'paths': <String>[],
            'timeoutMs': 1000,
          }),
          throwsA(isA<CliCleanupWorkerStartFailure>()),
        );

        expect(
          _existingCleanupPrivateDirs(),
          before,
          reason:
              'the private directory created for the ready marker must be '
              'removed even when the worker never confirms ready',
        );
      },
      skip: io.Platform.isWindows
          ? false
          : 'launches a real Windows PowerShell cleanup worker',
      timeout: const Timeout(Duration(seconds: 40)),
    );
  });
}

/// A real [IoCliProcessLauncher] whose [deletePrivateDirectory] seam always
/// throws [cleanupError] in place of actually removing the private
/// directory. Overriding this one method, rather than the whole class,
/// exercises startCleanupWorker's own handling of a real cleanup failure
/// (a warning on success, folded into the thrown
/// [CliCleanupWorkerStartFailure]'s message on failure) through the real
/// adapter, since nothing portable lets a test provoke a real
/// directory-deletion failure at exactly this point otherwise. Production
/// code never overrides this.
class _FailingCleanupDirectoryLauncher extends IoCliProcessLauncher {
  _FailingCleanupDirectoryLauncher(
    this.cleanupError, {
    super.startupTimeout = cleanupWorkerStartupTimeout,
  });

  final Object cleanupError;

  @override
  void deletePrivateDirectory(io.Directory privateDir) {
    throw cleanupError;
  }
}

/// Decodes UTF-16LE [bytes] to UTF-16 code units. The inverse of the
/// encoding [cleanupWorkerEncodedBootstrapScript] uses, kept local to this
/// test: production code never needs to decode its own encoded command back.
List<int> _decodeUtf16Le(List<int> bytes) {
  final units = <int>[];
  for (var i = 0; i + 1 < bytes.length; i += 2) {
    units.add(bytes[i] | (bytes[i + 1] << 8));
  }
  return units;
}
