import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'cli_platform_ops.dart';

/// Linux implementation of [PlatformOps].
///
/// Extracted from macss's `LinuxPlatformOps` and inquiry's, which agreed on
/// every operation: `tar` for archive extraction, the process environment
/// for reads, and a no-op write (the install script handles PATH).
class LinuxPlatformOps implements PlatformOps {
  LinuxPlatformOps({
    required this.binaryName,
    required this.assetName,
    this.postInstallArguments = const ['version'],
  });

  @override
  final String binaryName;

  @override
  final String assetName;

  final List<String> postInstallArguments;

  @override
  Future<void> expandArchive(String archivePath, String destDir) async {
    final result = await Process.run('tar', [
      'xzf',
      archivePath,
      '-C',
      destDir,
    ]);
    if (result.exitCode != 0) {
      throw ProcessException(
        'tar',
        ['xzf', archivePath],
        'Failed to extract archive: ${result.stderr}',
        result.exitCode,
      );
    }
  }

  @override
  String? getEnvVariable(String name) => Platform.environment[name];

  @override
  Future<void> setEnvVariable(String name, String value) async {
    // Persistent env vars on Linux require modifying shell profiles. This is
    // a no-op at runtime: the install script handles PATH setup during
    // installation.
  }

  @override
  Future<ProcessResult> runPostInstall(String installDir, {Duration? timeout}) {
    final result = Process.run(
      p.join(installDir, 'bin', binaryName),
      postInstallArguments,
    );
    if (timeout == null) return result;
    return result.timeout(
      timeout,
      onTimeout: () => throw TimeoutException(
        '$binaryName did not finish within ${timeout.inSeconds}s',
      ),
    );
  }

  @override
  Future<void> scheduleDeletion(String dir) async {
    // The running binary is not locked on Linux (unlike Windows, which
    // needs the deferred, detached dance in WindowsPlatformOps), so this
    // deletes synchronously: uninstall must not report success, or a
    // swallowed failure, before the directory is actually gone (issue #40).
    // A previous version spawned a detached `rm -rf` and returned as soon
    // as it started, which raced `uninstall`'s own success report and lost
    // any real deletion error (a permission problem, for example) inside
    // the detached process.
    try {
      await Directory(dir).delete(recursive: true);
    } on PathNotFoundException {
      // Nothing to remove. Matches the previous `rm -rf` behavior, which
      // never failed on a directory that was already gone.
    }
  }
}
