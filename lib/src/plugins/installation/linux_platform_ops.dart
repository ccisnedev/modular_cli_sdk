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
    // a no-op at runtime — the install script handles PATH setup during
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
    // The running binary is not locked on Linux — delete directly.
    await Process.start('rm', ['-rf', dir], mode: ProcessStartMode.detached);
  }
}
