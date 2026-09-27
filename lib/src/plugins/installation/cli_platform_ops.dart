import 'dart:io';

import 'linux_platform_ops.dart';
import 'macos_platform_ops.dart';
import 'windows_platform_ops.dart';

/// How long a post-install verification/deploy step may take before it is
/// abandoned. Generous enough for a cold filesystem, short enough that a
/// stalled step reports rather than hanging the terminal.
const postInstallTimeout = Duration(seconds: 60);

/// Cross-platform abstraction for the OS-specific shell operations `upgrade`
/// and `uninstall` need: archive extraction, environment variables, running
/// the freshly installed binary, and scheduling a directory's deletion.
///
/// Extracted from macss's `targets/platform_ops.dart` and inquiry's
/// `hosts/platform_ops.dart`, which agreed on every member here. Path
/// manipulation is NOT part of this abstraction — use `package:path`.
abstract class PlatformOps {
  /// The compiled binary name for this platform (e.g. `macss.exe` or
  /// `macss`).
  String get binaryName;

  /// The release asset name for this platform (e.g. `macss-windows-x64.zip`).
  String get assetName;

  /// Extract an archive to [destDir].
  ///
  /// Windows: PowerShell `Expand-Archive`. Linux/macOS: `tar xzf`.
  Future<void> expandArchive(String archivePath, String destDir);

  /// Read a system environment variable. Returns `null` if not set.
  String? getEnvVariable(String name);

  /// Write a system environment variable.
  ///
  /// A no-op on Linux/macOS: persistent PATH changes there are made by the
  /// install script, not at runtime.
  Future<void> setEnvVariable(String name, String value);

  /// Run the freshly installed binary at `<installDir>/bin/<binaryName>`
  /// with this configuration's post-install arguments, bounded by
  /// [postInstallTimeout].
  ///
  /// Returns the child's result so the caller can report what actually
  /// happened: a step whose output is swallowed is indistinguishable from
  /// one that did nothing.
  Future<ProcessResult> runPostInstall(String installDir);

  /// Schedule deletion of a directory after the current process exits.
  ///
  /// Windows: rename the running exe, spawn a detached `cmd /c` script that
  /// waits briefly then `rmdir /s /q`s the directory. Linux/macOS: spawn a
  /// detached `rm -rf`.
  Future<void> scheduleDeletion(String dir);

  /// Returns the implementation for the current OS, configured with
  /// [executable] (the base binary name, without a platform extension),
  /// [assets] (a release asset name per `Platform.operatingSystem`), and
  /// [postInstallArguments] (what [runPostInstall] passes to the binary).
  factory PlatformOps.current({
    required String executable,
    required Map<String, String> assets,
    List<String> postInstallArguments = const ['version'],
  }) {
    final os = Platform.operatingSystem;
    final assetName = assets[os];
    if (assetName == null) {
      throw UnsupportedError(
        'PlatformOps: no release asset configured for OS "$os". '
        'Configured platforms: ${assets.keys.join(', ')}.',
      );
    }
    if (Platform.isWindows) {
      return WindowsPlatformOps(
        binaryName: '$executable.exe',
        assetName: assetName,
        postInstallArguments: postInstallArguments,
      );
    }
    if (Platform.isLinux) {
      return LinuxPlatformOps(
        binaryName: executable,
        assetName: assetName,
        postInstallArguments: postInstallArguments,
      );
    }
    if (Platform.isMacOS) {
      return MacosPlatformOps(
        binaryName: executable,
        assetName: assetName,
        postInstallArguments: postInstallArguments,
      );
    }
    throw UnsupportedError('PlatformOps: unsupported OS "$os"');
  }
}
