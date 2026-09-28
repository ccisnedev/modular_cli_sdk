import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'cli_platform_ops.dart';

/// Windows implementation of [PlatformOps].
///
/// Extracted from macss's `WindowsPlatformOps` and inquiry's, which agreed on
/// every operation: PowerShell for archive extraction and environment
/// variables, and a rename-aside-then-detached-script dance for deleting a
/// directory that contains the running executable.
class WindowsPlatformOps implements PlatformOps {
  WindowsPlatformOps({
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
    final result = await Process.run('powershell', [
      '-NoProfile',
      '-Command',
      'Expand-Archive -Path "$archivePath" -DestinationPath "$destDir" -Force',
    ]);
    if (result.exitCode != 0) {
      throw ProcessException(
        'powershell',
        ['Expand-Archive'],
        'Failed to extract archive: ${result.stderr}',
        result.exitCode,
      );
    }
  }

  @override
  String? getEnvVariable(String name) {
    final result = Process.runSync('powershell', [
      '-NoProfile',
      '-Command',
      '[System.Environment]::GetEnvironmentVariable("$name", "User")',
    ]);
    if (result.exitCode != 0) return null;
    final value = (result.stdout as String).trim();
    return value.isEmpty ? null : value;
  }

  @override
  Future<void> setEnvVariable(String name, String value) async {
    Process.runSync('powershell', [
      '-NoProfile',
      '-Command',
      '[System.Environment]::SetEnvironmentVariable("$name", "$value", "User")',
    ]);
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
    // Rename the running exe so the directory can be deleted.
    final currentExe = File(Platform.resolvedExecutable);
    final bakPath = '${Platform.resolvedExecutable}.bak';
    try {
      currentExe.renameSync(bakPath);
    } on FileSystemException {
      // Best effort: may already be renamed by an earlier attempt.
    }

    // A temp batch script, to avoid cmd.exe quoting issues: Dart escapes "
    // in Process.start args, but cmd doesn't understand \".
    final bat = File(
      p.join(Directory.systemTemp.path, '${binaryName}_cleanup.cmd'),
    );
    bat.writeAsStringSync(
      '@echo off\r\n'
      'timeout /t 2 /nobreak >nul\r\n'
      'rmdir /s /q "$dir"\r\n'
      'del "%~f0"\r\n',
    );

    await Process.start('cmd.exe', [
      '/c',
      bat.path,
    ], mode: ProcessStartMode.detached);
  }
}
