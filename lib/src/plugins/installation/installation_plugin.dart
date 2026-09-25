import 'package:preview_executor/preview_executor.dart';
import 'package:pub_semver/pub_semver.dart' as semver;

import '../../cli_plugin.dart';
import '../../command.dart';
import '../../command_exception.dart';
import '../../exit_codes.dart';
import '../../explains_nothing_to_do.dart';
import '../../input.dart';
import '../../output.dart';
import '../doctor_plugin.dart';
import 'cli_downloader.dart';
import 'cli_file_system.dart';
import 'cli_platform.dart';
import 'cli_release_source.dart';

/// `upgrade` / `uninstall` — installs a compiled release of this CLI over
/// itself, and removes it. Also contributes three checks to `doctor.checks`
/// (binary on `PATH`, alias, release), which is why it [CliPluginManifest.requires]
/// `modular_cli.doctor`: those checks have nowhere to be reported without it.
///
/// `assets` maps a [CliPlatform.operatingSystem] key to the name of the
/// release asset for that platform — itself the compiled, ready-to-run
/// executable this plugin writes over [CliInstallationConfig.executable]'s
/// current location. Neither an archive to extract nor an installer to run
/// is part of this release: nothing in the issue or the consumer spec this
/// was built against describes one, and inventing an extraction format would
/// be exactly the kind of fallback the rest of this SDK avoids.
class InstallationPlugin implements CliPlugin {
  InstallationPlugin({
    required this.config,
    CliReleaseSource? releaseSource,
    CliDownloader? downloader,
    CliFileSystem? fileSystem,
    CliPlatform? platform,
  }) : releaseSource = releaseSource ?? HttpCliReleaseSource(),
       downloader = downloader ?? HttpCliDownloader(),
       fileSystem = fileSystem ?? const IoCliFileSystem(),
       platform = platform ?? const IoCliPlatform();

  final CliInstallationConfig config;
  final CliReleaseSource releaseSource;
  final CliDownloader downloader;
  final CliFileSystem fileSystem;
  final CliPlatform platform;

  @override
  CliPluginManifest get manifest => CliPluginManifest(
    id: 'modular_cli.installation',
    displayName: 'Installation',
    version: '1.0.0',
    hostApiVersion: '^$cliPluginHostApiVersion',
    requires: const ['modular_cli.doctor'],
  );

  @override
  void setup(CliPluginHost host) {
    host.contribute<CliDoctorCheck>(
      DoctorPlugin.extensionPoint,
      CliDoctorCheck(name: 'binary', run: _checkBinary),
    );
    host.contribute<CliDoctorCheck>(
      DoctorPlugin.extensionPoint,
      CliDoctorCheck(name: 'alias', run: _checkAlias),
    );
    host.contribute<CliDoctorCheck>(
      DoctorPlugin.extensionPoint,
      CliDoctorCheck(name: 'release', run: () => _checkRelease(host)),
    );

    host.registerCommand<UpgradeInput, UpgradeOutput>(
      'upgrade',
      (req) => UpgradeCommand(
        UpgradeInput(),
        config: config,
        releaseSource: releaseSource,
        downloader: downloader,
        fileSystem: fileSystem,
        platform: platform,
        currentVersion: host.metadata().version,
      ),
      description: 'Upgrade to the latest release',
    );
    host.registerCommand<UninstallInput, UninstallOutput>(
      'uninstall',
      (req) => UninstallCommand(UninstallInput(), config: config, fileSystem: fileSystem),
      description: 'Remove this CLI',
    );
  }

  Future<CliCheckResult> _checkBinary() async {
    final path = fileSystem.resolveOnPath(config.executable);
    return path != null
        ? CliCheckResult(status: CliCheckStatus.ok, message: '${config.executable} found at $path')
        : CliCheckResult(
            status: CliCheckStatus.error,
            message: '${config.executable} was not found on PATH',
          );
  }

  Future<CliCheckResult> _checkAlias() async {
    final aliasPath = fileSystem.resolveOnPath(config.alias);
    final binaryPath = fileSystem.resolveOnPath(config.executable);
    if (aliasPath == null) {
      return CliCheckResult(
        status: CliCheckStatus.error,
        message: '${config.alias} was not found on PATH',
      );
    }
    if (aliasPath != binaryPath) {
      return CliCheckResult(
        status: CliCheckStatus.error,
        message: '${config.alias} resolves to $aliasPath, not ${config.executable}',
      );
    }
    return CliCheckResult(
      status: CliCheckStatus.ok,
      message: '${config.alias} resolves to ${config.executable}',
    );
  }

  Future<CliCheckResult> _checkRelease(CliPluginHost host) async {
    final List<CliRelease> releases;
    try {
      releases = await releaseSource.listReleases(config.repository);
    } on Object catch (e) {
      return CliCheckResult(
        status: CliCheckStatus.warning,
        message: 'Could not check for a newer release: $e',
      );
    }

    final latest = latestTaggedRelease(releases, config.tagPrefix);
    if (latest == null) {
      return CliCheckResult(
        status: CliCheckStatus.warning,
        message: 'No release with tag prefix "${config.tagPrefix}" was found in ${config.repository}.',
      );
    }

    final latestVersion = semver.Version.parse(latest.tagName.substring(config.tagPrefix.length));
    final current = semver.Version.parse(host.metadata().version);
    return latestVersion > current
        ? CliCheckResult(
            status: CliCheckStatus.warning,
            message: 'A newer release is available: ${latest.tagName} (current: ${host.metadata().version}).',
          )
        : CliCheckResult(status: CliCheckStatus.ok, message: 'Up to date (${host.metadata().version}).');
  }
}

/// What [InstallationPlugin] needs to know about this CLI's own
/// distribution. Every field is required: a silently-defaulted repository or
/// asset name would install the wrong CLI, or nothing at all, without saying
/// so.
class CliInstallationConfig {
  const CliInstallationConfig({
    required this.repository,
    required this.tagPrefix,
    required this.executable,
    required this.alias,
    required this.assets,
  });

  /// `owner/repo` on GitHub — e.g. `'ccisnedev/calculatrix'`.
  final String repository;

  /// The prefix this CLI's own release tags carry — e.g. `'cli-v'` in a
  /// repository whose application releases are tagged `v*`. Only tags
  /// starting with this prefix are considered.
  final String tagPrefix;

  /// The name of the binary on `PATH` — e.g. `'cx'`.
  final String executable;

  /// A second name this CLI is also expected to resolve under.
  final String alias;

  /// [CliPlatform.operatingSystem] → the name of the release asset for that
  /// platform.
  final Map<String, String> assets;
}

/// The newest release among [releases] whose tag starts with [tagPrefix] and
/// parses as semver once the prefix is stripped. A tag that does not parse —
/// or does not carry the prefix at all, such as an application's own `v*` tag
/// living in the same repository as this CLI's `cli-v*` — is skipped rather
/// than guessed at.
CliRelease? latestTaggedRelease(List<CliRelease> releases, String tagPrefix) {
  CliRelease? best;
  semver.Version? bestVersion;
  for (final release in releases) {
    if (!release.tagName.startsWith(tagPrefix)) continue;
    final semver.Version version;
    try {
      version = semver.Version.parse(release.tagName.substring(tagPrefix.length));
    } on FormatException {
      continue;
    }
    if (bestVersion == null || version > bestVersion) {
      best = release;
      bestVersion = version;
    }
  }
  return best;
}

CliReleaseAsset? assetForPlatform(
  CliRelease release,
  Map<String, String> assets,
  String operatingSystem,
) {
  final name = assets[operatingSystem];
  if (name == null) return null;
  for (final asset in release.assets) {
    if (asset.name == name) return asset;
  }
  return null;
}

// ── upgrade ──────────────────────────────────────────────────────────────

class UpgradeInput extends Input {
  UpgradeInput();

  @override
  Map<String, dynamic> toJson() => const {};
}

class UpgradeOutput extends Output {
  UpgradeOutput({
    required this.stepsCompleted,
    required this.exitCode,
    this.errorId,
    this.errorMessage,
    this.installedVersion,
  });

  final List<String> stepsCompleted;
  final String? errorId;
  final String? errorMessage;
  final String? installedVersion;

  @override
  final int exitCode;

  @override
  Map<String, dynamic> toJson() => {
    if (errorId != null) 'error': errorId,
    if (errorMessage != null) 'message': errorMessage,
    'stepsCompleted': stepsCompleted,
    if (installedVersion != null) 'version': installedVersion,
  };
}

/// Thrown by an upgrade/uninstall [Step] when it fails — carries the
/// structured id (`download-failed`, `file-access-denied`) the consumer spec
/// requires an `--apply` failure to report. [PreviewExecutor.perform] catches
/// it, stops the run without performing any step after it, and keeps it as
/// [Execution.failure] — `describe` reads it back from there.
class CliInstallStepFailure implements Exception {
  const CliInstallStepFailure(this.id, this.message);

  final String id;
  final String message;

  @override
  String toString() => message;
}

class UpgradeCommand
    implements Command<UpgradeInput, UpgradeOutput>, ExplainsNothingToDo {
  UpgradeCommand(
    this.input, {
    required this.config,
    required this.releaseSource,
    required this.downloader,
    required this.fileSystem,
    required this.platform,
    required this.currentVersion,
  });

  @override
  final UpgradeInput input;

  final CliInstallationConfig config;
  final CliReleaseSource releaseSource;
  final CliDownloader downloader;
  final CliFileSystem fileSystem;
  final CliPlatform platform;
  final String currentVersion;

  String? _nothingToDo;
  String? _latestVersion;

  @override
  String? get nothingToDo => _nothingToDo;

  @override
  String? validate() => null;

  @override
  Future<List<Step>> steps() async {
    final List<CliRelease> releases;
    try {
      releases = await releaseSource.listReleases(config.repository);
    } on Object catch (e) {
      throw CommandException(
        code: 'release-lookup-failed',
        message: 'Could not look up releases for ${config.repository}: $e',
        exitCode: ExitCode.genericError,
      );
    }

    final latest = latestTaggedRelease(releases, config.tagPrefix);
    if (latest == null) {
      throw CommandException(
        code: 'release-lookup-failed',
        message: 'No release with tag prefix "${config.tagPrefix}" was found in ${config.repository}.',
        exitCode: ExitCode.genericError,
      );
    }

    final latestVersion = semver.Version.parse(latest.tagName.substring(config.tagPrefix.length));
    final current = semver.Version.parse(currentVersion);
    if (latestVersion <= current) {
      _nothingToDo = 'already on the latest version ($currentVersion)';
      return const [];
    }
    _latestVersion = latestVersion.toString();

    final asset = assetForPlatform(latest, config.assets, platform.operatingSystem);
    if (asset == null) {
      throw CommandException(
        code: 'release-lookup-failed',
        message: 'Release ${latest.tagName} has no asset for platform "${platform.operatingSystem}".',
        exitCode: ExitCode.genericError,
      );
    }

    final installPath = fileSystem.resolveOnPath(config.executable);
    if (installPath == null) {
      throw CommandException(
        code: 'file-access-denied',
        message: '${config.executable} is not on PATH; there is nowhere to install it.',
        exitCode: ExitCode.genericError,
      );
    }

    final download = DownloadAssetStep(downloader: downloader, url: asset.downloadUrl, assetName: asset.name);
    final install = InstallExecutableStep(fileSystem: fileSystem, path: installPath, download: download);
    return [download, install];
  }

  @override
  UpgradeOutput describe(Execution execution) {
    final stepsCompleted = execution.outcomes.map((o) => o.target).toList();

    final failure = execution.failure;
    if (failure != null) {
      final error = failure.error;
      final id = error is CliInstallStepFailure ? error.id : 'download-failed';
      final message = error is CliInstallStepFailure ? error.message : failure.message;
      return UpgradeOutput(
        stepsCompleted: stepsCompleted,
        exitCode: ExitCode.genericError,
        errorId: id,
        errorMessage: message,
      );
    }

    return UpgradeOutput(
      stepsCompleted: stepsCompleted,
      exitCode: ExitCode.ok,
      installedVersion: _latestVersion,
    );
  }
}

class DownloadAssetStep implements Step {
  DownloadAssetStep({required this.downloader, required this.url, required this.assetName});

  final CliDownloader downloader;
  final String url;
  final String assetName;

  @override
  Preview preview() => Preview(verb: 'download', target: assetName, pending: const ['bytes']);

  @override
  Future<Outcome> perform(StepContext context) async {
    final List<int> bytes;
    try {
      bytes = await downloader.download(url);
    } on Object catch (e) {
      throw CliInstallStepFailure('download-failed', 'Could not download $assetName: $e');
    }
    return Outcome(verb: 'download', target: assetName, values: {'bytes': bytes});
  }
}

class InstallExecutableStep implements Step {
  InstallExecutableStep({required this.fileSystem, required this.path, required this.download});

  final CliFileSystem fileSystem;
  final String path;
  final Step download;

  @override
  Preview preview() => Preview(verb: 'install', target: path);

  @override
  Future<Outcome> perform(StepContext context) async {
    final bytes = context.outcomeOf(download).values['bytes'] as List<int>;
    try {
      await fileSystem.writeExecutable(path, bytes);
    } on Object catch (e) {
      throw CliInstallStepFailure('file-access-denied', 'Could not write $path: $e');
    }
    return Outcome(verb: 'install', target: path);
  }
}

// ── uninstall ────────────────────────────────────────────────────────────

class UninstallInput extends Input {
  UninstallInput();

  @override
  Map<String, dynamic> toJson() => const {};
}

class UninstallOutput extends Output {
  UninstallOutput({required this.removed, required this.exitCode, this.errorId, this.errorMessage});

  final List<String> removed;
  final String? errorId;
  final String? errorMessage;

  @override
  final int exitCode;

  @override
  Map<String, dynamic> toJson() => {
    if (errorId != null) 'error': errorId,
    if (errorMessage != null) 'message': errorMessage,
    'removed': removed,
  };
}

class UninstallCommand
    implements Command<UninstallInput, UninstallOutput>, ExplainsNothingToDo {
  UninstallCommand(this.input, {required this.config, required this.fileSystem});

  @override
  final UninstallInput input;

  final CliInstallationConfig config;
  final CliFileSystem fileSystem;

  String? _nothingToDo;

  @override
  String? get nothingToDo => _nothingToDo;

  @override
  String? validate() => null;

  @override
  Future<List<Step>> steps() async {
    final steps = <Step>[];

    final executablePath = fileSystem.resolveOnPath(config.executable);
    if (executablePath != null) {
      steps.add(RemoveFileStep(fileSystem: fileSystem, path: executablePath));
    }

    // The alias is only ever removed here when it currently points at this
    // same binary — an alias resolving elsewhere, or not at all, is left
    // alone rather than guessed at.
    final aliasPath = fileSystem.resolveOnPath(config.alias);
    if (aliasPath != null && aliasPath == executablePath) {
      steps.add(RemoveFileStep(fileSystem: fileSystem, path: aliasPath));
    }

    if (steps.isEmpty) {
      _nothingToDo = '${config.executable} is not on PATH; there is nothing to remove';
    }
    return steps;
  }

  @override
  UninstallOutput describe(Execution execution) {
    final removed = execution.outcomes.map((o) => o.target).toList();

    final failure = execution.failure;
    if (failure != null) {
      final error = failure.error;
      final id = error is CliInstallStepFailure ? error.id : 'file-access-denied';
      final message = error is CliInstallStepFailure ? error.message : failure.message;
      return UninstallOutput(
        removed: removed,
        exitCode: ExitCode.genericError,
        errorId: id,
        errorMessage: message,
      );
    }

    return UninstallOutput(removed: removed, exitCode: ExitCode.ok);
  }
}

class RemoveFileStep implements Step {
  RemoveFileStep({required this.fileSystem, required this.path});

  final CliFileSystem fileSystem;
  final String path;

  @override
  Preview preview() => Preview(verb: 'remove', target: path);

  @override
  Future<Outcome> perform(StepContext context) async {
    try {
      await fileSystem.delete(path);
    } on Object catch (e) {
      throw CliInstallStepFailure('file-access-denied', 'Could not remove $path: $e');
    }
    return Outcome(verb: 'remove', target: path);
  }
}
