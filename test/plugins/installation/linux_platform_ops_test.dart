@TestOn('linux')
library;

/// `LinuxPlatformOps.runPostInstall`'s wait, against a real slow process.
///
/// See `windows_platform_ops_test.dart` for why this matters: macss's own
/// `runPostInstall` never bounds the wait, and extracting it alongside
/// inquiry's (whose own best-effort host redeploy does bound it) wired
/// that bound in unconditionally, which the verification path this SDK runs
/// by default (matching macss) should never have inherited.
///
/// A real shell script stands in for the freshly installed binary: a
/// genuine child process with a controllable, short real-world duration, so
/// this pins actual wall-clock behavior rather than the shape of the code.
import 'dart:async';
import 'dart:io';

import 'package:modular_cli_sdk/modular_cli_sdk.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory installDir;

  setUp(() {
    installDir = Directory.systemTemp.createTempSync('mcs_linux_platform_ops_');
    Directory(p.join(installDir.path, 'bin')).createSync(recursive: true);
    final script = File(p.join(installDir.path, 'bin', 'slow.sh'))
      ..writeAsStringSync('#!/bin/sh\nsleep 1\n');
    Process.runSync('chmod', ['+x', script.path]);
  });

  tearDown(() {
    installDir.deleteSync(recursive: true);
  });

  LinuxPlatformOps ops() => LinuxPlatformOps(
    binaryName: 'slow.sh',
    assetName: 'irrelevant',
    postInstallArguments: const [],
  );

  test('an explicit timeout is honored', () async {
    await expectLater(
      ops().runPostInstall(
        installDir.path,
        timeout: const Duration(milliseconds: 200),
      ),
      throwsA(isA<TimeoutException>()),
    );
  });

  test(
    'with no timeout, waits for the process to finish, matching macss',
    () async {
      final result = await ops().runPostInstall(installDir.path);

      expect(result.exitCode, 0);
    },
  );
}
