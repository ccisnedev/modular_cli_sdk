/// Doubles for `InstallationPlugin`'s tests: fakes for the release lookup,
/// the download, and the platform ops it drives `upgrade`/`uninstall`
/// through, so no test in this directory reaches the network, extracts a
/// real archive, or touches a real PATH.
///
/// Modeled on macss's and inquiry's own test fakes (`FakePlatformOps` in
/// `platform_ops_test.dart`/`uninstall_test.dart`): a calls list a test
/// asserts against, rather than a mock framework.
library;

import 'dart:io';

import 'package:modular_cli_sdk/modular_cli_sdk.dart';

/// Serves canned releases, and counts how each lookup method was asked —
/// [latestRelease] (the no-`tagPrefix` path both macss and inquiry actually
/// use) and [listReleases] (the `tagPrefix` path) separately, so a test can
/// assert the plugin asked the one it meant to and not the other.
class FakeReleaseSource implements CliReleaseSource {
  FakeReleaseSource({this.releases = const [], this.error});

  final List<CliRelease> releases;
  final Object? error;

  int latestReleaseCalls = 0;
  int listReleasesCalls = 0;

  @override
  Future<CliRelease?> latestRelease(String repository) async {
    latestReleaseCalls++;
    if (error != null) throw error!;
    return releases.isEmpty ? null : releases.first;
  }

  @override
  Future<List<CliRelease>> listReleases(String repository) async {
    listReleasesCalls++;
    if (error != null) throw error!;
    return releases;
  }
}

/// A callable stand-in for [Downloader]: `FakeDownloader()` itself is a
/// `Future<void> Function(String, String)`, so it can be passed anywhere a
/// [Downloader] is expected.
class FakeDownloader {
  FakeDownloader({this.error, this.onDownload});

  final Object? error;

  /// Called at the point a real download would have happened, before
  /// [call] returns. Lets a test mutate shared state (a fake platform ops'
  /// environment, for instance) at exactly the moment between a step's plan
  /// and its own perform.
  final void Function()? onDownload;

  /// Every URL asked for, in order.
  final List<String> requested = [];

  Future<void> call(String url, String destination) async {
    requested.add(url);
    onDownload?.call();
    if (error != null) throw error!;
  }
}

/// A [PlatformOps] that records every call instead of touching a real
/// archive, environment, or child process.
class FakePlatformOps implements PlatformOps {
  FakePlatformOps({
    this.binaryName = 'cx',
    this.assetName = 'cx-linux',
    this.fakeEnvValue,
    this.expandArchiveError,
    this.setEnvVariableError,
    this.scheduleDeletionError,
    this.runPostInstallError,
    this.postInstallResult,
  });

  @override
  final String binaryName;

  @override
  final String assetName;

  /// What [getEnvVariable] returns for every name, unless overridden by a
  /// specific entry in [envOverrides].
  final String? fakeEnvValue;

  /// Per-variable overrides for [getEnvVariable], checked before
  /// [fakeEnvValue].
  final Map<String, String> envOverrides = {};

  final Object? expandArchiveError;
  final Object? setEnvVariableError;
  final Object? scheduleDeletionError;

  /// Thrown by [runPostInstall] instead of returning, standing in for macss's
  /// own failure mode: the freshly extracted binary cannot even be launched
  /// (`ProcessException`), which is what makes its inline verification a hard
  /// failure rather than a check whose result is inspected.
  final Object? runPostInstallError;

  /// What [runPostInstall] returns when it does not throw. Defaults to a
  /// clean exit, matching a verification that passes.
  final ProcessResult? postInstallResult;

  /// Every call this fake received, in order, as a human-readable line —
  /// exactly macss's and inquiry's own `FakePlatformOps.calls` shape.
  final List<String> calls = [];

  @override
  Future<void> expandArchive(String archivePath, String destDir) async {
    calls.add('expandArchive($archivePath, $destDir)');
    if (expandArchiveError != null) throw expandArchiveError!;
  }

  @override
  String? getEnvVariable(String name) {
    calls.add('getEnvVariable($name)');
    return envOverrides[name] ?? fakeEnvValue;
  }

  @override
  Future<void> setEnvVariable(String name, String value) async {
    calls.add('setEnvVariable($name, $value)');
    if (setEnvVariableError != null) throw setEnvVariableError!;
  }

  @override
  Future<ProcessResult> runPostInstall(
    String installDir, {
    Duration? timeout,
  }) async {
    calls.add(
      timeout == null
          ? 'runPostInstall($installDir)'
          : 'runPostInstall($installDir, timeout: $timeout)',
    );
    if (runPostInstallError != null) throw runPostInstallError!;
    return postInstallResult ?? ProcessResult(0, 0, '', '');
  }

  @override
  Future<void> scheduleDeletion(String dir) async {
    calls.add('scheduleDeletion($dir)');
    if (scheduleDeletionError != null) throw scheduleDeletionError!;
  }
}
