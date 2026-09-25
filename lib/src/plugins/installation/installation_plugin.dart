import 'package:preview_executor/preview_executor.dart';
import 'package:pub_semver/pub_semver.dart' as semver;

import '../../cli_plugin.dart';
import '../../command.dart';
import '../../command_exception.dart';
import '../../exit_codes.dart';
import '../../explains_nothing_to_do.dart';
import '../../input.dart';
import '../../output.dart';
import '../../skips_interactive_approval.dart';
import '../doctor_plugin.dart';
import 'cli_downloader.dart';
import 'cli_file_system.dart';
import 'cli_platform.dart';
import 'cli_process_launcher.dart';
import 'cli_release_source.dart';

/// `upgrade` / `uninstall`: installs a compiled release of this CLI over
/// itself, and removes it. Also contributes three checks to `doctor.checks`
/// (binary on `PATH`, alias, release), which is why it [CliPluginManifest.requires]
/// `modular_cli.doctor`: those checks have nowhere to be reported without it.
///
/// `assets` maps a [CliPlatform.operatingSystem] key to the name of the
/// release asset for that platform (itself the compiled, ready-to-run
/// executable this plugin writes over [CliInstallationConfig.executable]'s
/// current location). Neither an archive to extract nor an installer to run
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
    CliProcessLauncher? processLauncher,
  }) : releaseSource = releaseSource ?? HttpCliReleaseSource(),
       downloader = downloader ?? HttpCliDownloader(),
       fileSystem = fileSystem ?? const IoCliFileSystem(),
       platform = platform ?? const IoCliPlatform(),
       processLauncher = processLauncher ?? const IoCliProcessLauncher();

  final CliInstallationConfig config;
  final CliReleaseSource releaseSource;
  final CliDownloader downloader;
  final CliFileSystem fileSystem;
  final CliPlatform platform;
  final CliProcessLauncher processLauncher;

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
      (req) => UninstallCommand(
        UninstallInput(),
        config: config,
        fileSystem: fileSystem,
        platform: platform,
        processLauncher: processLauncher,
      ),
      description: 'Remove this CLI',
    );
  }

  Future<CliCheckResult> _checkBinary() async {
    final String? path;
    try {
      path = fileSystem.resolveOnPath(config.executable);
    } on Object catch (e) {
      return CliCheckResult(
        status: CliCheckStatus.error,
        message:
            'could not check whether ${config.executable} is on PATH: $e',
      );
    }
    return path != null
        ? CliCheckResult(
            status: CliCheckStatus.ok,
            message: '${config.executable} found at $path',
          )
        : CliCheckResult(
            status: CliCheckStatus.error,
            message: '${config.executable} was not found on PATH',
          );
  }

  Future<CliCheckResult> _checkAlias() async {
    final String? aliasPath;
    final String? binaryPath;
    try {
      aliasPath = fileSystem.resolveOnPath(config.alias);
      binaryPath = fileSystem.resolveOnPath(config.executable);
    } on Object catch (e) {
      return CliCheckResult(
        status: CliCheckStatus.error,
        message: 'could not check whether ${config.alias} is on PATH: $e',
      );
    }
    if (aliasPath == null) {
      return CliCheckResult(
        status: CliCheckStatus.error,
        message: '${config.alias} was not found on PATH',
      );
    }
    // Compared by same-file identity, not by path string: a valid symlink
    // (`cx -> calculatrix`) resolves under each name to a different path on
    // disk even though both ultimately open the same file, and a
    // string-equality check would report that as broken. sameFile also
    // catches a hard-linked alias, which canonicalize alone cannot: a hard
    // link has no symlink target to resolve, so two hard-linked paths
    // canonicalize to two different strings despite naming the same inode.
    final isSameBinary =
        binaryPath != null && fileSystem.sameFile(aliasPath, binaryPath);
    if (!isSameBinary) {
      return CliCheckResult(
        status: CliCheckStatus.error,
        message:
            '${config.alias} resolves to $aliasPath, not ${config.executable}',
      );
    }
    final hardLinkIssue = hardLinkedAliasIssue(
      fileSystem,
      config,
      aliasPath,
      binaryPath,
    );
    if (hardLinkIssue != null) {
      return CliCheckResult(status: CliCheckStatus.error, message: hardLinkIssue);
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

    final CliRelease? latest;
    try {
      latest = latestTaggedRelease(releases, config.tagPrefix);
    } on CliInvalidReleaseTag catch (e) {
      return CliCheckResult(
        status: CliCheckStatus.warning,
        message:
            'Release ${e.tagName} in ${config.repository} does not parse as '
            'semver once the tag prefix "${config.tagPrefix}" is stripped.',
      );
    }
    if (latest == null) {
      return CliCheckResult(
        status: CliCheckStatus.warning,
        message:
            'No release with tag prefix "${config.tagPrefix}" was found in ${config.repository}.',
      );
    }

    final latestVersion = semver.Version.parse(
      latest.tagName.substring(config.tagPrefix.length),
    );
    final current = semver.Version.parse(host.metadata().version);
    return latestVersion > current
        ? CliCheckResult(
            status: CliCheckStatus.warning,
            message:
                'A newer release is available: ${latest.tagName} '
                '(current: ${host.metadata().version}). Run '
                '"${config.alias} upgrade --apply" to install it.',
          )
        : CliCheckResult(
            status: CliCheckStatus.ok,
            message: 'Up to date (${host.metadata().version}).',
          );
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

  /// `owner/repo` on GitHub, e.g. `'ccisnedev/calculatrix'`.
  final String repository;

  /// The prefix this CLI's own release tags carry, e.g. `'cli-v'` in a
  /// repository whose application releases are tagged `v*`. Only tags
  /// starting with this prefix are considered.
  final String tagPrefix;

  /// The name of the binary on `PATH`, e.g. `'cx'`.
  final String executable;

  /// A second name this CLI is also expected to resolve under.
  final String alias;

  /// [CliPlatform.operatingSystem] → the name of the release asset for that
  /// platform.
  final Map<String, String> assets;
}

/// Thrown by [latestTaggedRelease] when a release's tag carries [CliInstallationConfig.tagPrefix]
/// but the remainder does not parse as semver, e.g. `cli-vnightly` under the
/// prefix `cli-v`. Surfaced rather than skipped: a tag this CLI's own release
/// process produced and cannot make sense of is a fact about the repository
/// worth reporting, not a candidate quietly passed over in favor of the next
/// one that happens to parse.
class CliInvalidReleaseTag implements Exception {
  const CliInvalidReleaseTag(this.tagName);

  /// The tag that did not parse, exactly as GitHub returned it.
  final String tagName;

  @override
  String toString() =>
      'Tag "$tagName" does not parse as semver once its prefix is stripped.';
}

/// The newest release among [releases] whose tag starts with [tagPrefix] and
/// parses as semver once the prefix is stripped, or null when no release
/// carries [tagPrefix] at all. A tag with no [tagPrefix] (an application's
/// own `v*` tag living in the same repository as this CLI's `cli-v*`) is not
/// a candidate and is skipped without comment. A tag that does carry
/// [tagPrefix] but fails to parse once it is stripped is a different thing:
/// [CliInvalidReleaseTag] is thrown rather than silently passed over, because
/// treating it as absent could report a repository as up to date against a
/// release nobody actually superseded.
CliRelease? latestTaggedRelease(List<CliRelease> releases, String tagPrefix) {
  CliRelease? best;
  semver.Version? bestVersion;
  for (final release in releases) {
    if (!release.tagName.startsWith(tagPrefix)) continue;
    final semver.Version version;
    try {
      version = semver.Version.parse(
        release.tagName.substring(tagPrefix.length),
      );
    } on FormatException {
      throw CliInvalidReleaseTag(release.tagName);
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

/// Whether [config]'s alias is currently a hard link to its executable
/// rather than a symlink, or the exact same raw path, or not resolving to
/// the same file at all.
///
/// [CliFileSystem.sameFile] reports a hard link as the same file as its
/// target, but [CliFileSystem.canonicalize], which only ever resolves
/// symlinks, still reports the two raw paths as different: neither is a
/// symlink pointing at the other for it to follow. That combination -
/// [CliFileSystem.sameFile] true, the two raw paths unequal, and
/// [CliFileSystem.canonicalize] disagreeing on them - is exactly what a hard
/// link looks like and a symlinked alias does not.
///
/// A hard-linked alias is the one alias shape this plugin does not support:
/// it can exist on disk (a package manager, a previous manual install, may
/// have created one) but this plugin only ever creates, and only ever
/// updates, a symlinked alias, so a hard-linked one is reported rather than
/// silently accepted as-is or silently rewritten into something else.
///
/// Returns null when [aliasPath] or [executablePath] is null, when they are
/// the same raw path, when they do not resolve to the same file at all, or
/// when they resolve to the same file by way of a symlink rather than a
/// hard link: none of those is the hard-link problem this checks for, and
/// each is either fine or a different, already-reported problem.
String? hardLinkedAliasIssue(
  CliFileSystem fileSystem,
  CliInstallationConfig config,
  String? aliasPath,
  String? executablePath,
) {
  if (aliasPath == null || executablePath == null) return null;
  if (aliasPath == executablePath) return null;

  final bool isSameFile;
  try {
    isSameFile = fileSystem.sameFile(aliasPath, executablePath);
  } on Object {
    return null;
  }
  if (!isSameFile) return null;

  final bool sameCanonicalTarget;
  try {
    sameCanonicalTarget =
        fileSystem.canonicalize(aliasPath) ==
        fileSystem.canonicalize(executablePath);
  } on Object {
    return null;
  }
  if (sameCanonicalTarget) return null;

  return '${config.alias} is a hard link to ${config.executable}, not a '
      'symlink. Hard-linked aliases are not supported: recreate '
      '${config.alias} as a symlink to ${config.executable}.';
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

/// Thrown by an upgrade/uninstall [Step] when it fails, carries the
/// structured id (`download-failed`, `file-access-denied`) the consumer spec
/// requires an `--apply` failure to report. [PreviewExecutor.perform] catches
/// it, stops the run without performing any step after it, and keeps it as
/// [Execution.failure]: `describe` reads it back from there.
class CliInstallStepFailure implements Exception {
  const CliInstallStepFailure(this.id, this.message);

  final String id;
  final String message;

  @override
  String toString() => message;
}

class UpgradeCommand
    implements
        Command<UpgradeInput, UpgradeOutput>,
        ExplainsNothingToDo,
        SkipsInteractiveApproval {
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

    final CliRelease? latest;
    try {
      latest = latestTaggedRelease(releases, config.tagPrefix);
    } on CliInvalidReleaseTag catch (e) {
      throw CommandException(
        code: 'release-lookup-failed',
        message:
            'Release ${e.tagName} in ${config.repository} does not parse as '
            'semver once the tag prefix "${config.tagPrefix}" is stripped.',
        exitCode: ExitCode.genericError,
      );
    }
    if (latest == null) {
      throw CommandException(
        code: 'release-lookup-failed',
        message:
            'No release with tag prefix "${config.tagPrefix}" was found in ${config.repository}.',
        exitCode: ExitCode.genericError,
      );
    }

    final latestVersion = semver.Version.parse(
      latest.tagName.substring(config.tagPrefix.length),
    );
    final current = semver.Version.parse(currentVersion);
    if (latestVersion <= current) {
      _nothingToDo = 'already on the latest version ($currentVersion)';
      return const [];
    }
    _latestVersion = latestVersion.toString();

    final asset = assetForPlatform(
      latest,
      config.assets,
      platform.operatingSystem,
    );
    if (asset == null) {
      throw CommandException(
        code: 'release-lookup-failed',
        message:
            'Release ${latest.tagName} has no asset for platform "${platform.operatingSystem}".',
        exitCode: ExitCode.genericError,
      );
    }

    final String? installPath;
    try {
      installPath = fileSystem.resolveOnPath(config.executable);
    } on Object catch (e) {
      throw CommandException(
        code: 'executable-check-failed',
        message: 'Could not check whether ${config.executable} is on PATH: $e',
        exitCode: ExitCode.genericError,
      );
    }
    if (installPath == null) {
      throw CommandException(
        code: 'file-access-denied',
        message:
            '${config.executable} is not on PATH; there is nowhere to install it.',
        exitCode: ExitCode.genericError,
      );
    }

    // Resolved before planning, not written to blindly: config.executable
    // may itself be a symlink (a distro package manager, or a previous
    // install, having put the real binary elsewhere and pointed PATH's
    // entry at it through a link). Writing to the un-resolved path would
    // replace the link itself with a plain file, leaving whatever the link
    // used to point at untouched and un-upgraded, and severing the link. The
    // resolved path is what actually gets written, and what the plan
    // reports, so an approver sees the real target rather than the alias.
    final String resolvedPath;
    try {
      resolvedPath = fileSystem.canonicalize(installPath);
    } on Object catch (e) {
      throw CommandException(
        code: 'file-access-denied',
        message: 'Could not resolve $installPath to an install target: $e',
        exitCode: ExitCode.genericError,
      );
    }

    // Checked at plan time, and checked again inside InstallExecutableStep
    // immediately before the actual write: an alias that is a hard link to
    // the executable, rather than a symlink, is not a shape this plugin
    // supports creating or updating, and is reported rather than silently
    // accepted or silently rewritten.
    String? aliasPath;
    try {
      aliasPath = fileSystem.resolveOnPath(config.alias);
    } on Object catch (e) {
      throw CommandException(
        code: 'executable-check-failed',
        message: 'Could not check whether ${config.alias} is on PATH: $e',
        exitCode: ExitCode.genericError,
      );
    }
    final hardLinkIssue = hardLinkedAliasIssue(
      fileSystem,
      config,
      aliasPath,
      installPath,
    );
    if (hardLinkIssue != null) {
      throw CommandException(
        code: 'alias-hard-link-unsupported',
        message: hardLinkIssue,
        exitCode: ExitCode.genericError,
      );
    }

    final download = DownloadAssetStep(
      downloader: downloader,
      url: asset.downloadUrl,
      assetName: asset.name,
    );
    final install = InstallExecutableStep(
      fileSystem: fileSystem,
      config: config,
      path: resolvedPath,
      download: download,
    );
    return [download, install];
  }

  @override
  UpgradeOutput describe(Execution execution) {
    final stepsCompleted = execution.outcomes.map((o) => o.target).toList();

    final failure = execution.failure;
    if (failure != null) {
      final error = failure.error;
      final id = error is CliInstallStepFailure ? error.id : 'download-failed';
      final message = error is CliInstallStepFailure
          ? error.message
          : failure.message;
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
  DownloadAssetStep({
    required this.downloader,
    required this.url,
    required this.assetName,
  });

  final CliDownloader downloader;
  final String url;
  final String assetName;

  @override
  Preview preview() =>
      Preview(verb: 'download', target: assetName, pending: const ['bytes']);

  @override
  Future<Outcome> perform(StepContext context) async {
    final List<int> bytes;
    try {
      bytes = await downloader.download(url);
    } on Object catch (e) {
      throw CliInstallStepFailure(
        'download-failed',
        'Could not download $assetName: $e',
      );
    }
    return Outcome(
      verb: 'download',
      target: assetName,
      values: {'bytes': bytes},
    );
  }
}

class InstallExecutableStep implements Step {
  InstallExecutableStep({
    required this.fileSystem,
    required this.config,
    required this.path,
    required this.download,
  });

  final CliFileSystem fileSystem;
  final CliInstallationConfig config;

  /// The install target [UpgradeCommand.steps] resolved and planned to
  /// write to. Revalidated against a fresh resolution immediately before
  /// the write below, rather than trusted as still current: `--apply`
  /// computes its own plan, asks for approval, then executes within the
  /// same run, and this is the only point still ahead of the write where
  /// that plan can be checked against what is actually on disk right now.
  final String path;

  final Step download;

  @override
  Preview preview() => Preview(verb: 'install', target: path);

  @override
  Future<Outcome> perform(StepContext context) async {
    final bytes = context.outcomeOf(download).values['bytes'] as List<int>;

    // Re-resolve the original PATH entry and require it still resolves to
    // [path], the exact target this plan showed. Nothing is written on any
    // mismatch: the entry disappearing from PATH, resolving somewhere else
    // now, or the target no longer being a plain file are all reported as
    // install-target-changed rather than risking a write through whatever
    // is there now.
    final String? reResolvedInstallPath;
    try {
      reResolvedInstallPath = fileSystem.resolveOnPath(config.executable);
    } on Object catch (e) {
      throw CliInstallStepFailure(
        'executable-check-failed',
        'Could not check whether ${config.executable} is on PATH: $e',
      );
    }
    if (reResolvedInstallPath == null) {
      throw CliInstallStepFailure(
        'install-target-changed',
        '${config.executable} is no longer on PATH; it resolved to $path '
            'when this plan was built.',
      );
    }

    final String reResolvedTarget;
    try {
      reResolvedTarget = fileSystem.canonicalize(reResolvedInstallPath);
    } on Object catch (e) {
      throw CliInstallStepFailure(
        'install-target-changed',
        'Could not resolve $reResolvedInstallPath to an install target any '
            'more: $e. It resolved to $path when this plan was built.',
      );
    }
    if (reResolvedTarget != path) {
      throw CliInstallStepFailure(
        'install-target-changed',
        '${config.executable} now resolves to $reResolvedTarget, not $path '
            'as it did when this plan was built.',
      );
    }

    if (!fileSystem.isRegularFile(path)) {
      throw CliInstallStepFailure(
        'install-target-changed',
        '$path is no longer a regular file; refusing to write over it.',
      );
    }

    // Checked again here, not only when the plan was built: the alias could
    // have been turned into a hard link to the executable in the same
    // window a symlinked PATH entry could have been repointed in.
    String? aliasPath;
    try {
      aliasPath = fileSystem.resolveOnPath(config.alias);
    } on Object catch (e) {
      throw CliInstallStepFailure(
        'executable-check-failed',
        'Could not check whether ${config.alias} is on PATH: $e',
      );
    }
    final hardLinkIssue = hardLinkedAliasIssue(
      fileSystem,
      config,
      aliasPath,
      reResolvedInstallPath,
    );
    if (hardLinkIssue != null) {
      throw CliInstallStepFailure('alias-hard-link-unsupported', hardLinkIssue);
    }

    try {
      await fileSystem.writeExecutable(path, bytes);
    } on Object catch (e) {
      throw CliInstallStepFailure(
        'file-access-denied',
        'Could not write $path: $e',
      );
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
  UninstallOutput({
    required this.removed,
    required this.exitCode,
    this.scheduled = const [],
    this.errorId,
    this.errorMessage,
    this.notes = const [],
  });

  final List<String> removed;

  /// Paths a step scheduled for removal rather than removing outright, e.g.
  /// [SelfDeleteExecutableStep] on Windows: the running executable is moved
  /// aside and a cleanup worker is told to delete it once this process
  /// exits, so at the point this output is printed it has not actually been
  /// removed yet. Reported separately from [removed] so this never claims a
  /// deletion that has not happened.
  final List<String> scheduled;

  /// Explanatory notes a step attached to its outcome, e.g.
  /// [SelfDeleteExecutableStep]'s "will be removed when this process exits":
  /// prose an outcome's verb and target alone cannot say, and that must
  /// still reach whoever reads this output rather than being dropped.
  final List<String> notes;

  final String? errorId;
  final String? errorMessage;

  @override
  final int exitCode;

  @override
  Map<String, dynamic> toJson() => {
    if (errorId != null) 'error': errorId,
    if (errorMessage != null) 'message': errorMessage,
    'removed': removed,
    'scheduled': scheduled,
    if (notes.isNotEmpty) 'notes': notes,
  };
}

class UninstallCommand
    implements
        Command<UninstallInput, UninstallOutput>,
        ExplainsNothingToDo,
        SkipsInteractiveApproval {
  UninstallCommand(
    this.input, {
    required this.config,
    required this.fileSystem,
    required this.platform,
    required this.processLauncher,
  });

  @override
  final UninstallInput input;

  final CliInstallationConfig config;
  final CliFileSystem fileSystem;
  final CliPlatform platform;
  final CliProcessLauncher processLauncher;

  String? _nothingToDo;

  @override
  String? get nothingToDo => _nothingToDo;

  @override
  String? validate() => null;

  @override
  Future<List<Step>> steps() async {
    final steps = <Step>[];

    final String? executablePath;
    final String? aliasPath;
    try {
      executablePath = fileSystem.resolveOnPath(config.executable);
      aliasPath = fileSystem.resolveOnPath(config.alias);
    } on Object catch (e) {
      throw CommandException(
        code: 'executable-check-failed',
        message:
            'Could not check whether ${config.executable} or '
            '${config.alias} is on PATH: $e',
        exitCode: ExitCode.genericError,
      );
    }

    // The alias is only ever removed here when it currently points at this
    // same binary: an alias resolving elsewhere, or not at all, is left
    // alone rather than guessed at. Compared by sameFile identity, not by
    // path string, for the same reason _checkAlias is: a valid symlink (or
    // hard link) resolves under each name to a different path on disk even
    // though both ultimately open the same file. When both names resolve to
    // the exact same raw path, only one delete step is queued; the entry is
    // removed once, as the executable, rather than twice.
    //
    // sameFile resolves both paths through canonicalize before comparing
    // them, and canonicalize is strict: a resolution failure (a dangling
    // link in the chain, a permission error) is thrown rather than
    // swallowed. That failure is turned into the same file-access-denied
    // CommandException every other build failure here reports, rather than
    // being let through as a raw, unhandled exception.
    //
    // The whole comparison, including the step it may queue, stays inside
    // this one null-check so aliasPath and executablePath stay promoted to
    // non-null throughout: splitting the boolean result out into its own
    // variable for use further down loses that promotion.
    if (aliasPath != null && executablePath != null) {
      final bool isSameBinary;
      try {
        isSameBinary = fileSystem.sameFile(aliasPath, executablePath);
      } on Object catch (e) {
        throw CommandException(
          code: 'file-access-denied',
          message: 'Could not compare $aliasPath with $executablePath: $e',
          exitCode: ExitCode.genericError,
        );
      }
      // The alias's own step is queued before the executable's: deleting
      // the target first would leave the symlinked alias dangling, and
      // File.delete on a dangling symlink fails on Linux (it stats through
      // the link before removing it, and a dangling link has nothing at
      // the other end to stat). Removing the alias while it is still a
      // valid link, then the target, avoids that failure entirely.
      if (isSameBinary && aliasPath != executablePath) {
        steps.add(RemoveFileStep(fileSystem: fileSystem, path: aliasPath));
      }
    }

    if (executablePath != null) {
      // On Windows, the running executable cannot simply be deleted: the
      // loader holds it open. It is instead moved aside and a detached
      // process is started to delete it once this one has exited.
      steps.add(
        platform.operatingSystem == 'windows'
            ? SelfDeleteExecutableStep(
                fileSystem: fileSystem,
                processLauncher: processLauncher,
                path: executablePath,
              )
            : RemoveFileStep(fileSystem: fileSystem, path: executablePath),
      );
    }

    if (steps.isEmpty) {
      _nothingToDo =
          '${config.executable} is not on PATH; there is nothing to remove';
    }
    return steps;
  }

  @override
  UninstallOutput describe(Execution execution) {
    // 'remove' outcomes are actually gone; 'schedule' outcomes (only ever
    // from SelfDeleteExecutableStep, on Windows) are only moved aside so
    // far, with the real deletion left to a cleanup worker that runs after
    // this process exits. Reporting the two under the same list would claim
    // a deletion that has not happened yet.
    final removed = execution.outcomes
        .where((o) => o.verb == 'remove')
        .map((o) => o.target)
        .toList();
    final scheduled = execution.outcomes
        .where((o) => o.verb == 'schedule')
        .map((o) => o.target)
        .toList();
    final notes = execution.outcomes
        .map((o) => o.detail)
        .whereType<String>()
        .toList();

    final failure = execution.failure;
    if (failure != null) {
      final error = failure.error;
      final id = error is CliInstallStepFailure
          ? error.id
          : 'file-access-denied';
      final message = error is CliInstallStepFailure
          ? error.message
          : failure.message;
      return UninstallOutput(
        removed: removed,
        scheduled: scheduled,
        exitCode: ExitCode.genericError,
        errorId: id,
        errorMessage: message,
        notes: notes,
      );
    }

    return UninstallOutput(
      removed: removed,
      scheduled: scheduled,
      exitCode: ExitCode.ok,
      notes: notes,
    );
  }
}

/// Removes the currently-running executable on Windows, where a plain
/// delete of it is not possible: the loader keeps a mapped executable's
/// directory entry from being deleted (though, since Vista, not from being
/// renamed) while it is running.
///
/// [path] is moved aside to `<path>.uninstall-<pid>.old`, then a detached
/// PowerShell cleanup worker is started
/// ([CliProcessLauncher.startCleanupWorker]) that waits for this process
/// (identified by [CliProcessLauncher.currentPid]) to exit before deleting
/// the renamed file. This step's own [Outcome] uses the verb `schedule`,
/// not `remove`: from the caller's perspective the path is gone from `PATH`
/// once the move succeeds, but the file itself has not actually been
/// deleted yet, and [UninstallCommand.describe] relies on that verb to keep
/// the two apart. [preview] says explicitly that the actual deletion
/// happens later, so `--plan`/`--apply` output does not imply the file
/// disappears the instant this step runs.
///
/// Starting the cleanup worker is not allowed to fail silently: if
/// [CliProcessLauncher.startCleanupWorker] throws, this step fails with
/// `cleanup-start-failed` naming the renamed file, rather than reporting a
/// success that leaves a `.old` file behind forever.
class SelfDeleteExecutableStep implements Step {
  SelfDeleteExecutableStep({
    required this.fileSystem,
    required this.processLauncher,
    required this.path,
  });

  final CliFileSystem fileSystem;
  final CliProcessLauncher processLauncher;
  final String path;

  @override
  Preview preview() => Preview(
    verb: 'schedule',
    target: path,
    detail: '$path will be removed when this process exits',
  );

  @override
  Future<Outcome> perform(StepContext context) async {
    final pid = processLauncher.currentPid;
    final renamedPath = '$path.uninstall-$pid.old';

    try {
      await fileSystem.rename(path, renamedPath);
    } on Object catch (e) {
      throw CliInstallStepFailure(
        'file-access-denied',
        'Could not move $path aside for removal: $e',
      );
    }

    try {
      await processLauncher.startCleanupWorker({
        'parentPid': pid,
        'paths': [renamedPath],
        'timeoutMs': cleanupWorkerParentExitTimeoutMs,
      });
    } on Object catch (e) {
      throw CliInstallStepFailure(
        'cleanup-start-failed',
        '$path was moved to $renamedPath but the cleanup worker that '
            'removes it could not be started: $e. Delete $renamedPath '
            'manually.',
      );
    }

    return Outcome(
      verb: 'schedule',
      target: path,
      detail: '$path will be removed when this process exits',
    );
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
      throw CliInstallStepFailure(
        'file-access-denied',
        'Could not remove $path: $e',
      );
    }
    return Outcome(verb: 'remove', target: path);
  }
}
