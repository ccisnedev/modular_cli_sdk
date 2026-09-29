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
    String? currentExecutable,
  }) : currentExecutable = currentExecutable ?? Platform.resolvedExecutable;

  @override
  final String binaryName;

  @override
  final String assetName;

  final List<String> postInstallArguments;

  /// The executable [scheduleDeletion] renames aside before scheduling the
  /// directory that contains it for deletion.
  ///
  /// **Injected, and that is not optional.** `Platform.resolvedExecutable`
  /// is this CLI's own compiled binary only when a compiled binary is what
  /// is running. Under `dart test` it is the Dart VM, so a test that
  /// reached the default would rename the Dart SDK's own executable. See
  /// [ReplaceInstallation.runningExecutable] in installation_plugin.dart,
  /// which the same reasoning already applies to.
  final String currentExecutable;

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
    final currentExe = File(currentExecutable);
    final bakPath = '$currentExecutable.bak';
    try {
      currentExe.renameSync(bakPath);
    } on FileSystemException {
      // Best effort: may already be renamed by an earlier attempt.
    }

    // A temp batch script, to avoid cmd.exe quoting issues: Dart escapes "
    // in Process.start args, but cmd doesn't understand \". The directory
    // is written directly into the script rather than passed as an
    // argument, for the same reason.
    final bat = File(
      p.join(Directory.systemTemp.path, '${binaryName}_cleanup.cmd'),
    );
    bat.writeAsStringSync(_cleanupScript(dir));

    await Process.start('cmd.exe', [
      '/c',
      bat.path,
    ], mode: ProcessStartMode.detached);
  }

  /// The cleanup script [scheduleDeletion] writes and runs.
  ///
  /// Retries up to 40 times, 250 ms apart (about 10 s in total), stopping
  /// as soon as the directory is gone: parity with docmd's own
  /// pre-InstallationPlugin cleanup script (a PowerShell equivalent — see
  /// `uninstall.dart`'s `_windowsUninstallScript` before commit
  /// `7055232`), which used the same 40-attempts/250ms budget and this
  /// carries over unchanged (issue #40, defect 2). The previous version of
  /// this script waited `timeout /t 2` exactly once, so an executable still
  /// locked past that single 2 s window (a slow exit, antivirus, an
  /// indexer) was left behind for good.
  ///
  /// The loop runs in a single PowerShell process because cmd.exe has no
  /// sub-second sleep. `ping -n 1 -w 250 127.0.0.1` does not wait 250 ms
  /// (`-w` is a reply timeout and localhost replies at once), so 40 of
  /// them cost only process startup: under 1 s from a console and 7.7 to
  /// 9.5 s from a detached process. PowerShell reads the path from the
  /// `target` environment variable the script sets, never from its own
  /// command text, so no PowerShell quoting is involved, and
  /// `-LiteralPath` keeps `[`, `]` and `*` literal.
  ///
  /// [dir] is embedded directly in the script text, not passed as a
  /// argument on the command line: this is an internal cleanup script on a
  /// path the SDK itself controls, not a user-facing alias shim (the #37
  /// concerns do not apply), but the value still has to be escaped
  /// correctly for the batch language it is written in. `%` is doubled to
  /// `%%`, the standard way to write a literal percent sign in a `.cmd`
  /// file (an unescaped `%word%` is read as an environment variable
  /// reference, silently substituting whatever that variable holds, or
  /// nothing at all, in place of a real path segment). Wrapping every use
  /// of the resulting `%target%` value in double quotes is enough to make
  /// spaces, `&` and `^` literal: cmd.exe's line parser treats all three as
  /// plain characters inside a quoted string.
  static String _cleanupScript(String dir) {
    final escaped = dir.replaceAll('%', '%%');
    return '@echo off\r\n'
        'setlocal\r\n'
        'set "target=$escaped"\r\n'
        'powershell -NoProfile -NonInteractive -WindowStyle Hidden -Command "'
        r'for ($i = 0; $i -lt 40; $i++) { '
        r'Remove-Item -LiteralPath $env:target -Recurse -Force '
        '-ErrorAction SilentlyContinue; '
        r'if (-not (Test-Path -LiteralPath $env:target)) { break }; '
        'Start-Sleep -Milliseconds 250 }"\r\n'
        'del "%~f0"\r\n';
  }
}
