@TestOn('windows')
library;

/// `WindowsPlatformOps.runPostInstall`'s wait, against a real slow process.
///
/// macss's own `runPostInstall` (`code/cli/lib/targets/windows_platform_ops.dart`)
/// runs the freshly installed binary and awaits it with no timeout at all —
/// it is a hard-fail verification step, not a best-effort one, so there is
/// nothing to bound. Extracting it alongside inquiry's `runPostInstall`
/// (`code/cli/lib/hosts/windows_platform_ops.dart`), which does apply a 60s
/// timeout because it drives inquiry's best-effort host redeploy, wired the
/// timeout in unconditionally — so the verification path this SDK runs by
/// default (`CliInstallationConfig.verifyAfterInstall`, matching macss)
/// inherited a bound macss's own code never had.
///
/// Real `ping` calls stand in for the freshly installed binary: they are a
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
    installDir = Directory.systemTemp.createTempSync('mcs_win_platform_ops_');
    Directory(p.join(installDir.path, 'bin')).createSync(recursive: true);
    // `ping -n 2` takes just over one second: long enough to reliably outlast
    // a short explicit timeout, short enough to keep the suite fast without
    // one.
    File(p.join(installDir.path, 'bin', 'slow.cmd')).writeAsStringSync(
      '@echo off\r\nping -n 2 127.0.0.1 >nul\r\necho done\r\n',
    );
  });

  tearDown(() {
    installDir.deleteSync(recursive: true);
  });

  WindowsPlatformOps ops() => WindowsPlatformOps(
    binaryName: 'slow.cmd',
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
