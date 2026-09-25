import 'dart:io' as io;

/// The running platform, as [InstallationPlugin] needs to know it: which key
/// of [CliInstallationConfig.assets] names the asset for this machine.
/// Injectable so a test can exercise every platform branch without actually
/// running on each OS.
abstract class CliPlatform {
  /// `'linux'`, `'macos'` or `'windows'`, [io.Platform.operatingSystem]'s own
  /// vocabulary, reused rather than invented, since it is already what a
  /// [CliInstallationConfig.assets] key is compared against.
  String get operatingSystem;
}

class IoCliPlatform implements CliPlatform {
  const IoCliPlatform();

  @override
  String get operatingSystem => io.Platform.operatingSystem;
}
