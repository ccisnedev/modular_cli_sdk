@TestOn('linux')
library;

/// `LinuxPlatformOps.scheduleDeletion` against a real directory (issue #40,
/// defect 1).
///
/// The previous implementation spawned a detached `rm -rf` and returned as
/// soon as it was started:
///
/// ```dart
/// await Process.start('rm', ['-rf', dir], mode: ProcessStartMode.detached);
/// ```
///
/// `uninstall` then reports success immediately, while the directory may
/// still exist: a script that runs `uninstall` and immediately checks for
/// the directory, or reinstalls, races the detached `rm`. On Linux the
/// running executable is not locked (unlike Windows), so nothing requires
/// the deferred, detached deletion Windows needs: the fix deletes
/// synchronously and lets a real failure (for example, a permission
/// problem) propagate to the caller instead of being swallowed by a
/// fire-and-forget process.
import 'dart:io';

import 'package:modular_cli_sdk/modular_cli_sdk.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tempRoot;

  setUp(() {
    tempRoot = Directory.systemTemp.createTempSync('mcs_linux_deletion_test_');
  });

  tearDown(() {
    if (tempRoot.existsSync()) {
      // Best effort: a permission-denial test may have left the directory
      // locked down; put it back so cleanup does not itself fail.
      Process.runSync('chmod', ['-R', 'u+rwx', tempRoot.path]);
      tempRoot.deleteSync(recursive: true);
    }
  });

  LinuxPlatformOps ops() =>
      LinuxPlatformOps(binaryName: 'cx', assetName: 'cx-linux');

  test('the directory is gone by the time scheduleDeletion returns', () async {
    final installDir = Directory(p.join(tempRoot.path, 'install'))
      ..createSync(recursive: true);
    // A detached `rm -rf` on a single small file can finish before this
    // test ever gets to check for it, passing by accident even on the
    // racy implementation. Enough files that deleting them takes
    // measurable time makes the race observable: a detached, merely
    // *started* deletion reliably has not finished yet when checked right
    // after, while a synchronous one always has.
    for (var i = 0; i < 4000; i++) {
      File(p.join(installDir.path, 'file_$i.txt')).writeAsStringSync('x');
    }

    await ops().scheduleDeletion(installDir.path);

    // No polling, no delay: a synchronous delete means this is true the
    // instant scheduleDeletion returns, not eventually.
    expect(installDir.existsSync(), isFalse);
  });

  test('a missing directory is a no-op, not an error', () async {
    final missing = p.join(tempRoot.path, 'does-not-exist');

    await expectLater(ops().scheduleDeletion(missing), completes);
  });

  test('a real deletion failure is reported, not swallowed', () async {
    final installDir = Directory(p.join(tempRoot.path, 'locked-parent'))
      ..createSync(recursive: true);
    final child = Directory(p.join(installDir.path, 'child'))
      ..createSync(recursive: true);
    File(p.join(child.path, 'marker.txt')).writeAsStringSync('x');

    // Removing write+execute from the parent directory makes unlinking
    // `child` fail with a permission error: exactly the case the issue
    // calls out ("a failure, for example a permission error, is reported,
    // not swallowed").
    Process.runSync('chmod', ['444', installDir.path]);

    await expectLater(
      ops().scheduleDeletion(child.path),
      throwsA(isA<FileSystemException>()),
    );
  });
}
