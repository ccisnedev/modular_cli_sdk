import 'linux_platform_ops.dart';

/// macOS implementation of [PlatformOps].
///
/// Neither macss nor inquiry ship a macOS build today (their own
/// `PlatformOps.current()` factories only branch on `Platform.isWindows` /
/// `Platform.isLinux` and throw `UnsupportedError` otherwise), so there is no
/// macOS behavior to extract. This reuses [LinuxPlatformOps] verbatim — the
/// same `tar.gz` archive format and the same POSIX semantics for env
/// variables and deletion apply — as the closest existing precedent, rather
/// than inventing new macOS-specific behavior. See
/// `docs/installation-parity.md`.
class MacosPlatformOps extends LinuxPlatformOps {
  MacosPlatformOps({
    required super.binaryName,
    required super.assetName,
    super.postInstallArguments,
  });
}
