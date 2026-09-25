/// The cleanup worker's bootstrap script encoding, its stdin payload, and
/// (Windows-only) the real worker's behaviour against a real process and a
/// real file: it deletes nothing while the parent it was told to watch is
/// still alive, and deletes the given path once that parent exits.
library;

import 'dart:convert';
import 'dart:io' as io;

import 'package:modular_cli_sdk/modular_cli_sdk.dart';
import 'package:test/test.dart';

void main() {
  group('encodeUtf16LeBase64', () {
    test('encodes each UTF-16 code unit as two little-endian bytes', () {
      // 'A' is code unit 0x0041, 'B' is 0x0042: little-endian bytes low byte
      // first, so 0x41 0x00 0x42 0x00, which base64-encodes to QQBCAA==.
      expect(encodeUtf16LeBase64('AB'), 'QQBCAA==');
    });

    test('round-trips through decoding back to the original text', () {
      const text = 'READY\nfeature with punctuation: %, &, !, (), \'quotes\'';
      final decoded = String.fromCharCodes(
        _pairsToCodeUnits(base64.decode(encodeUtf16LeBase64(text))),
      );
      expect(decoded, text);
    });
  });

  group('encodedCleanupWorkerCommand', () {
    test('decodes back to the fixed bootstrap script', () {
      final decoded = String.fromCharCodes(
        _pairsToCodeUnits(
          base64.decode(encodedCleanupWorkerCommand()),
        ),
      );
      expect(decoded, cleanupWorkerBootstrapScript);
    });
  });

  group('cleanupWorkerBootstrapScript', () {
    // Fixed and never interpolated: every piece of run-specific data is
    // read once from stdin as JSON instead, so nothing here needs to escape
    // a path.
    test('reads its payload from stdin as JSON', () {
      expect(cleanupWorkerBootstrapScript, contains('ConvertFrom-Json'));
      expect(cleanupWorkerBootstrapScript, contains('[Console]::In.ReadToEnd()'));
    });

    test('retains a handle on the parent process before signalling ready', () {
      expect(cleanupWorkerBootstrapScript, contains('GetProcessById'));
      expect(cleanupWorkerBootstrapScript, contains(r'$parent.Handle'));
      final readyIndex = cleanupWorkerBootstrapScript.indexOf('READY');
      final handleIndex = cleanupWorkerBootstrapScript.indexOf(r'$parent.Handle');
      expect(handleIndex, greaterThanOrEqualTo(0));
      expect(readyIndex, greaterThan(handleIndex));
    });

    test('waits for the parent to exit before deleting anything', () {
      expect(cleanupWorkerBootstrapScript, contains('WaitForExit'));
      final waitIndex = cleanupWorkerBootstrapScript.indexOf('WaitForExit');
      final removeIndex = cleanupWorkerBootstrapScript.indexOf('Remove-Item');
      expect(removeIndex, greaterThan(waitIndex));
    });

    test('deletes with -LiteralPath under a Stop error action', () {
      expect(
        cleanupWorkerBootstrapScript,
        contains("\$ErrorActionPreference = 'Stop'"),
      );
      expect(cleanupWorkerBootstrapScript, contains('Remove-Item -LiteralPath'));
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

          // The worker has signalled READY, but the parent it is waiting on
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
  });
}

/// Groups [bytes] into little-endian UTF-16 code units, the inverse of the
/// byte-splitting [encodeUtf16LeBase64] does.
List<int> _pairsToCodeUnits(List<int> bytes) {
  final units = <int>[];
  for (var i = 0; i < bytes.length; i += 2) {
    units.add(bytes[i] | (bytes[i + 1] << 8));
  }
  return units;
}
