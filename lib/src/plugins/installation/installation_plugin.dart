import 'dart:io';

import 'package:path/path.dart' as p;
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
import 'cli_platform_ops.dart';
import 'cli_release_source.dart';

/// `upgrade` / `uninstall`: replaces this CLI's own installation with the
/// latest compiled release, and removes it. Also contributes one check to
/// `doctor.checks` (release), which is why it [CliPluginManifest.requires]
/// `modular_cli.doctor`: that check has nowhere to be reported without it.
///
/// `binary` and `alias` doctor checks existed here before 0.8.0 shipped and
/// were removed: neither macss nor inquiry checks its own binary or alias is
/// reachable (both assume it: `doctor` running at all proves it), so there
/// was no precedent to extract, and 0.8.0 is a pure extraction. See the
/// GitHub issue linked from docs/installation-parity.md for what they did and
/// how to bring them back.
///
/// Extracted from macss's and inquiry's own `upgrade`/`uninstall` commands,
/// which agreed on everything both faithfully reproduce here: the install
/// directory is derived from `Platform.resolvedExecutable`, not looked up on
/// `PATH`; the releases API is asked once while the plan is built; the
/// running executable is moved aside before Windows overwrites it; the alias
/// is never touched by either command, only by the install script that
/// created it. Where the two disagreed (macss verifies the new binary
/// inline, hard-fail, right after extraction; inquiry redeploys hosts as a
/// separate, lenient step afterward), both are expressible:
/// [CliInstallationConfig.verifyAfterInstall] (true by default, matching
/// macss, which needs nothing else) gates the inline check, and
/// [CliInstallationConfig.postUpgradeSteps] /
/// [CliInstallationConfig.preUninstallSteps] let a CLI supply its own extra
/// steps, exactly as inquiry does today (with `verifyAfterInstall: false`,
/// so its own lenient step is not duplicated by the hard-fail one). See
/// `docs/installation-parity.md`.
class InstallationPlugin implements CliPlugin {
  InstallationPlugin({
    required this.config,
    CliReleaseSource? releaseSource,
    PlatformOps? platformOps,
  }) : releaseSource = releaseSource ?? HttpCliReleaseSource(),
       platformOps =
           platformOps ??
           PlatformOps.current(
             executable: config.executable,
             assets: config.assets,
             postInstallArguments: config.postInstallArguments,
           );

  final CliInstallationConfig config;
  final CliReleaseSource releaseSource;
  final PlatformOps platformOps;

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
      CliDoctorCheck(name: 'release', run: () => _checkRelease(host)),
    );

    host.registerCommand<UpgradeInput, UpgradeOutput>(
      'upgrade',
      (req) => UpgradeCommand(
        UpgradeInput(),
        config: config,
        currentVersion: host.metadata().version,
        releaseSource: releaseSource,
        platformOps: platformOps,
      ),
      globals: true,
      description: 'Upgrade to the latest release',
    );
    host.registerCommand<UninstallInput, UninstallOutput>(
      'uninstall',
      (req) => UninstallCommand(
        UninstallInput(),
        config: config,
        platformOps: platformOps,
      ),
      globals: true,
      description: 'Remove this CLI',
    );
  }

  Future<CliCheckResult> _checkRelease(CliPluginHost host) async {
    final tagPrefix = config.tagPrefix;
    final CliRelease? latest;
    try {
      if (tagPrefix == null) {
        latest = await releaseSource.latestRelease(config.repository);
      } else {
        final releases = await releaseSource.listReleases(config.repository);
        latest = latestTaggedRelease(releases, tagPrefix);
      }
    } on CliInvalidReleaseTag catch (e) {
      // The task explicitly requires a lookup failure to be reported here.
      // inquiry's own equivalent (`checkLatestVersion` in
      // `src/version_check.dart`) is silent on any failure and returns
      // "no update"; this diverges from that precedent on purpose. See
      // docs/installation-parity.md and the open questions in the PR.
      return CliCheckResult(
        status: CliCheckStatus.warning,
        message:
            'Release ${e.tagName} in ${config.repository} does not parse as '
            'semver once the tag prefix "$tagPrefix" is stripped.',
      );
    } on Object catch (e) {
      return CliCheckResult(
        status: CliCheckStatus.warning,
        message: 'Could not check for a newer release: $e',
      );
    }

    if (latest == null) {
      return CliCheckResult(
        status: CliCheckStatus.warning,
        message: tagPrefix == null
            ? '${config.repository} has no releases.'
            : 'No release with tag prefix "$tagPrefix" was found in '
                  '${config.repository}.',
      );
    }

    final rawTag = latest.tagName;
    final versionString = tagPrefix != null
        ? rawTag.substring(tagPrefix.length)
        : (rawTag.startsWith('v') ? rawTag.substring(1) : rawTag);
    final current = host.metadata().version;

    final semver.Version latestVersion;
    final semver.Version currentVersion;
    try {
      latestVersion = semver.Version.parse(versionString);
      currentVersion = semver.Version.parse(current);
    } on FormatException catch (e) {
      return CliCheckResult(
        status: CliCheckStatus.warning,
        message: 'Could not compare versions: $e',
      );
    }

    return latestVersion > currentVersion
        ? CliCheckResult(
            status: CliCheckStatus.warning,
            message:
                'A newer release is available: $rawTag (current: $current). '
                'Run "${config.alias} upgrade --apply" to install it.',
          )
        : CliCheckResult(
            status: CliCheckStatus.ok,
            message: 'Up to date ($current).',
          );
  }
}

/// What [InstallationPlugin] needs to know about this CLI's own
/// distribution.
class CliInstallationConfig {
  const CliInstallationConfig({
    required this.repository,
    required this.executable,
    required this.alias,
    required this.assets,
    this.tagPrefix,
    this.postInstallArguments = const ['version'],
    this.verifyAfterInstall = true,
    this.postUpgradeSteps,
    this.preUninstallSteps,
  });

  /// `owner/repo` on GitHub, e.g. `'ccisnedev/macss'`.
  final String repository;

  /// The name of the binary on `PATH`, e.g. `'macss'`.
  final String executable;

  /// A second name this CLI is also expected to resolve under, e.g. `'ma'`.
  final String alias;

  /// [Platform.operatingSystem] → the name of the release asset for that
  /// platform, e.g. `{'windows': 'macss-windows-x64.zip'}`.
  final Map<String, String> assets;

  /// The prefix this CLI's own release tags carry, e.g. `'cli-v'` in a
  /// repository whose application releases are tagged `v*`. Absent (the
  /// shape both macss and inquiry use) means this CLI's tags are not shared
  /// with anything else in the repository, and the single `/releases/latest`
  /// call answers directly. Present means only tags starting with it are
  /// considered, and the newest one among them wins: a repository-sharing
  /// mechanism that predates this issue and is kept because dropping it
  /// would regress any CLI relying on it.
  final String? tagPrefix;

  /// Arguments [PlatformOps.runPostInstall] runs the freshly-installed
  /// binary with, e.g. `['version']` (macss, inquiry) or `['host', 'get',
  /// '--apply', '--autoapprove']` (a redeploy step supplied through
  /// [postUpgradeSteps]).
  final List<String> postInstallArguments;

  /// Whether [ReplaceInstallation] runs the freshly extracted binary with
  /// [postInstallArguments] immediately after extraction, and fails the
  /// upgrade if that fails, exactly what macss's own `ReplaceInstallation`
  /// does ("Verifying installation...", hard-fail, no `postUpgradeSteps`
  /// involved).
  ///
  /// Defaults to true, matching macss, which needs nothing else. A CLI whose
  /// own post-install step is lenient instead (inquiry's `RedeployHosts`,
  /// supplied through [postUpgradeSteps], which must never fail the upgrade
  /// over it) sets this to false, so the hard-fail check does not also run
  /// (with the same [postInstallArguments]) before that lenient step does.
  final bool verifyAfterInstall;

  /// Extra steps [UpgradeCommand] runs after [ReplaceInstallation], built
  /// from the install directory and the platform ops the upgrade itself
  /// used. This is where inquiry's `RedeployHosts`, a best-effort
  /// redeploy that never fails the upgrade, is expressed; a CLI with
  /// nothing to add after an upgrade, like macss, leaves this null.
  final List<Step> Function(String installDir, PlatformOps platformOps)?
  postUpgradeSteps;

  /// Extra steps [UninstallCommand] runs before [UnsetFromPath] and
  /// [DeleteInstallation]. This is where inquiry's `CleanDeployedHosts` is
  /// expressed.
  final List<Step> Function(String installDir, PlatformOps platformOps)?
  preUninstallSteps;
}

// ── upgrade ──────────────────────────────────────────────────────────────

class UpgradeInput extends Input {
  UpgradeInput({String? installDir})
    : installDir =
          installDir ?? p.dirname(p.dirname(Platform.resolvedExecutable));

  /// Derived from the running executable's own location, exactly as macss's
  /// and inquiry's `UpgradeInput.fromCliRequest` do: never looked up on
  /// `PATH`, so an upgrade always replaces the binary that is actually
  /// running rather than some other installation that happens to resolve
  /// first.
  final String installDir;

  @override
  Map<String, dynamic> toJson() => {'installDir': installDir};
}

/// Downloads a release and extracts it over the installation.
///
/// Everything this needs (which version, which asset, which URL) was
/// settled when the step was built, from **one** call to the releases API.
/// Asking again at perform time could answer differently: a release
/// published in between would be downloaded without ever having been
/// approved.
///
/// **It says what it is doing while it does it.** The plan states what
/// *will* happen; this states that it *is* happening, which is a different
/// thing and the only one that helps during a download of several
/// megabytes. It goes to [progress] (stderr by default), so `--json` stays
/// machine-readable.
///
/// When [verifyAfterInstall] is true (the default), runs the freshly
/// extracted binary with [PlatformOps.runPostInstall] immediately afterward,
/// exactly as macss's own `ReplaceInstallation` does: hard-fail semantics,
/// no `postUpgradeSteps` involved. A CLI that verifies (or redeploys)
/// leniently instead, from its own [CliInstallationConfig.postUpgradeSteps]
/// (inquiry's `RedeployHosts`) sets [verifyAfterInstall] to false so the
/// two do not run twice.
class ReplaceInstallation implements Step {
  ReplaceInstallation({
    required this.platformOps,
    required this.installDir,
    required this.from,
    required this.to,
    required this.asset,
    required this.downloadUrl,
    this.verifyAfterInstall = true,
    Downloader? downloader,
    IOSink? progress,
    String? runningExecutable,
  }) : downloader = downloader ?? downloadOverHttp,
       progress = progress ?? stderr,
       runningExecutable = runningExecutable ?? Platform.resolvedExecutable;

  final PlatformOps platformOps;
  final Downloader downloader;
  final String installDir;
  final String from;
  final String to;
  final String asset;
  final String downloadUrl;

  /// See [CliInstallationConfig.verifyAfterInstall].
  final bool verifyAfterInstall;

  /// Where the running commentary goes. Injected so a test can read it.
  final IOSink progress;

  /// The binary this step is replacing, which on Windows has to be moved
  /// aside before it can be overwritten.
  ///
  /// **Injected, and that is not optional.** `Platform.resolvedExecutable`
  /// is this CLI's own compiled binary only when a compiled binary is what
  /// is running. Under `dart test` it is the Dart VM, so a test that
  /// reached the default would rename the Dart SDK's own executable.
  final String runningExecutable;

  @override
  Preview preview() => Preview(
    verb: 'replace',
    target: installDir,
    detail: ['$from → $to', 'asset $asset', 'from $downloadUrl'].join('; '),
  );

  @override
  Future<Outcome> perform(StepContext context) async {
    final tempDir = Directory.systemTemp.createTempSync('cli_upgrade_');
    try {
      progress.writeln('Downloading $asset ($from → $to)...');
      final archiveFile = File(p.join(tempDir.path, asset));
      await downloader(downloadUrl, archiveFile.path);

      if (Platform.isWindows) {
        // The running executable cannot be overwritten in place, so it is
        // moved aside first and cleaned up on the way out, or on the next
        // upgrade, if the file is still locked.
        final bak = File('$runningExecutable.bak');
        if (bak.existsSync()) bak.deleteSync();
        File(runningExecutable).renameSync(bak.path);
      }

      progress.writeln('Extracting into $installDir...');
      await platformOps.expandArchive(archiveFile.path, installDir);

      if (Platform.isWindows) {
        try {
          final bak = File('$runningExecutable.bak');
          if (bak.existsSync()) bak.deleteSync();
        } on FileSystemException {
          // Still locked, cleaned up on the next upgrade.
        }
      }

      if (verifyAfterInstall) {
        progress.writeln('Verifying installation...');
        await platformOps.runPostInstall(installDir);
      }
    } finally {
      tempDir.deleteSync(recursive: true);
    }

    return Outcome(
      verb: 'replace',
      target: installDir,
      values: {'from': from, 'to': to},
    );
  }
}

class UpgradeOutput extends Output {
  UpgradeOutput({
    required this.previousVersion,
    required this.newVersion,
    required this.upgraded,
    this.reason,
    this.extra = const [],
  });

  final String previousVersion;
  final String newVersion;
  final bool upgraded;

  /// Why nothing happened, when nothing did.
  final String? reason;

  /// Outcomes from any [CliInstallationConfig.postUpgradeSteps], reported
  /// generically: the SDK does not know what a CLI's own steps do (an
  /// inquiry-style host redeploy, for instance), only that they ran.
  final List<Map<String, dynamic>> extra;

  @override
  Map<String, dynamic> toJson() => {
    'previousVersion': previousVersion,
    'newVersion': newVersion,
    'upgraded': upgraded,
    if (reason != null) 'reason': reason,
    if (extra.isNotEmpty) 'extra': extra,
  };

  @override
  int get exitCode => ExitCode.ok;

  @override
  String? toText() {
    if (!upgraded) return reason ?? 'Already on the latest version';
    final lines = ['✓ Upgraded: $previousVersion → $newVersion'];
    // Generic, not inquiry-specific: whatever detail a postUpgradeSteps
    // outcome carries (inquiry's RedeployHosts, when a redeploy comes back
    // incomplete, sets one naming the retry command) is worth a line here
    // too, not only under extra in the structured output.
    for (final entry in extra) {
      final detail = entry['detail'] as String?;
      if (detail != null) lines.add(detail);
    }
    return lines.join('\n');
  }
}

class UpgradeCommand
    implements Command<UpgradeInput, UpgradeOutput>, ExplainsNothingToDo {
  UpgradeCommand(
    this.input, {
    required this.config,
    required this.currentVersion,
    CliReleaseSource? releaseSource,
    PlatformOps? platformOps,
    this.downloader,
    this.progress,
    this.runningExecutable,
  }) : releaseSource = releaseSource ?? HttpCliReleaseSource(),
       platformOps =
           platformOps ??
           PlatformOps.current(
             executable: config.executable,
             assets: config.assets,
             postInstallArguments: config.postInstallArguments,
           );

  @override
  final UpgradeInput input;

  final CliInstallationConfig config;
  final String currentVersion;
  final CliReleaseSource releaseSource;
  final PlatformOps platformOps;

  /// How the release archive is fetched. A seam for the tests, and the
  /// reason [ReplaceInstallation] itself knows nothing about HTTP.
  final Downloader? downloader;

  /// Where the step's running commentary goes. A seam for the tests.
  final IOSink? progress;

  /// The binary being replaced. A seam for the tests, and never defaulted
  /// here, see [ReplaceInstallation.runningExecutable].
  final String? runningExecutable;

  String? _reason;
  String? _latestVersion;

  /// Being current is the ordinary outcome, not a non-answer. Without this
  /// the framework would report "nothing would change", which states the
  /// fact and withholds the only part worth reading.
  @override
  String? get nothingToDo => _reason;

  @override
  String? validate() => null;

  /// The releases API is asked **once**, here. That is what makes the plan
  /// honest: the version, the asset and the URL a person approves are the
  /// ones that get downloaded. Asking again inside the step could resolve a
  /// release published in the meantime, and the upgrade would then not be
  /// the one that was shown.
  @override
  Future<List<Step>> steps() async {
    final tagPrefix = config.tagPrefix;
    final CliRelease? latest;
    try {
      if (tagPrefix == null) {
        latest = await releaseSource.latestRelease(config.repository);
      } else {
        final releases = await releaseSource.listReleases(config.repository);
        latest = latestTaggedRelease(releases, tagPrefix);
      }
    } on CliInvalidReleaseTag catch (e) {
      throw CommandException(
        id: 'release-lookup-failed',
        message:
            'Release ${e.tagName} in ${config.repository} does not parse as '
            'semver once the tag prefix "$tagPrefix" is stripped.',
        exitCode: ExitCode.apiError,
      );
    } on Object catch (e) {
      throw CommandException(
        id: 'release-lookup-failed',
        message: 'Could not look up releases for ${config.repository}: $e',
        exitCode: ExitCode.apiError,
      );
    }

    if (latest == null) {
      if (tagPrefix != null) {
        // Unlike "the repository has no releases at all" below, this is not
        // a legitimate steady state to report and stop at: a tagPrefix that
        // matches nothing is a configuration or repository problem, and
        // README.md documents release-lookup-failed for it.
        throw CommandException(
          id: 'release-lookup-failed',
          message:
              'No release with tag prefix "$tagPrefix" was found in '
              '${config.repository}.',
          exitCode: ExitCode.apiError,
        );
      }
      _reason = '${config.repository} has no releases.';
      return const [];
    }

    // macss skips a prerelease latest release rather than offering to
    // upgrade to it; inquiry's own lookup carries no such check. Exercised
    // only on the tagPrefix-absent path, which is the one both CLIs
    // actually use (a single `/releases/latest` call, exactly like macss's).
    if (tagPrefix == null && latest.prerelease) {
      _reason = 'Latest release is a prerelease, skipping.';
      return const [];
    }

    final rawTag = latest.tagName;
    final String versionString;
    if (tagPrefix != null) {
      versionString = rawTag.substring(tagPrefix.length);
      final semver.Version latestSemver;
      final semver.Version currentSemver;
      try {
        latestSemver = semver.Version.parse(versionString);
        currentSemver = semver.Version.parse(currentVersion);
      } on FormatException catch (e) {
        throw CommandException(
          id: 'release-lookup-failed',
          message: 'Could not compare versions: $e',
          exitCode: ExitCode.apiError,
        );
      }
      if (latestSemver <= currentSemver) {
        _reason = 'Already on the latest version';
        return const [];
      }
    } else {
      versionString = rawTag.startsWith('v') ? rawTag.substring(1) : rawTag;
      if (versionString == currentVersion) {
        _reason = 'Already on the latest version';
        return const [];
      }
    }
    _latestVersion = versionString;

    final asset = assetForPlatform(
      latest,
      config.assets,
      Platform.operatingSystem,
    );
    if (asset == null) {
      throw CommandException(
        id: 'asset-not-found',
        message:
            'No ${config.assets[Platform.operatingSystem]} asset in release '
            '$rawTag.',
        exitCode: ExitCode.notFound,
      );
    }

    final installDir = input.installDir;
    return [
      ReplaceInstallation(
        platformOps: platformOps,
        downloader: downloader,
        installDir: installDir,
        from: currentVersion,
        to: versionString,
        asset: asset.name,
        downloadUrl: asset.downloadUrl,
        verifyAfterInstall: config.verifyAfterInstall,
        progress: progress,
        runningExecutable: runningExecutable,
      ),
      ...?config.postUpgradeSteps?.call(installDir, platformOps),
    ];
  }

  @override
  UpgradeOutput describe(Execution execution) {
    final extra = execution.outcomes
        .where((o) => o.verb != 'replace')
        .map(
          (o) => {
            'verb': o.verb,
            'target': o.target,
            if (o.detail != null) 'detail': o.detail,
            if (o.values.isNotEmpty) 'values': o.values,
          },
        )
        .toList();
    return UpgradeOutput(
      previousVersion: currentVersion,
      newVersion: _latestVersion ?? currentVersion,
      upgraded: execution.outcomes.any((o) => o.verb == 'replace'),
      reason: _reason,
      extra: extra,
    );
  }
}

// ── uninstall ────────────────────────────────────────────────────────────

class UninstallInput extends Input {
  UninstallInput({String? installDir})
    : installDir =
          installDir ?? p.dirname(p.dirname(Platform.resolvedExecutable));

  final String installDir;

  @override
  Map<String, dynamic> toJson() => {'installDir': installDir};
}

/// Takes the CLI's `bin/` off the user's PATH.
class UnsetFromPath implements Step {
  UnsetFromPath({required this.platformOps, required this.binDir});

  final PlatformOps platformOps;
  final String binDir;

  String get _target => '$binDir from your PATH';

  @override
  Preview preview() => Preview(verb: 'unset', target: _target);

  @override
  Future<Outcome> perform(StepContext context) async {
    final userPath = platformOps.getEnvVariable('PATH') ?? '';
    final sep = Platform.isWindows ? ';' : ':';
    final parts = userPath
        .split(sep)
        .where((part) => part.isNotEmpty)
        .where((part) => !_pathEquals(part, binDir))
        .toList();
    final newPath = parts.join(sep);
    if (newPath != userPath) {
      await platformOps.setEnvVariable('PATH', newPath);
    }
    return Outcome(verb: 'unset', target: _target);
  }

  bool _pathEquals(String a, String b) =>
      p.normalize(a).toLowerCase() == p.normalize(b).toLowerCase();
}

/// Schedules the installation directory for deletion.
///
/// Scheduled rather than done: on Windows the running executable lives
/// inside it and cannot delete itself.
class DeleteInstallation implements Step {
  DeleteInstallation({required this.platformOps, required this.installDir});

  final PlatformOps platformOps;
  final String installDir;

  @override
  Preview preview() => Preview(
    verb: 'delete',
    target: installDir,
    detail:
        'requisitions, projects and anything under version control are not '
        'touched: this removes the tool, not your work',
  );

  @override
  Future<Outcome> perform(StepContext context) async {
    await platformOps.scheduleDeletion(installDir);
    return Outcome(verb: 'delete', target: installDir);
  }
}

class UninstallOutput extends Output {
  UninstallOutput({required this.installDir, this.extra = const []});

  final String installDir;

  /// Outcomes from any [CliInstallationConfig.preUninstallSteps], reported
  /// generically, see [UpgradeOutput.extra].
  final List<Map<String, dynamic>> extra;

  @override
  Map<String, dynamic> toJson() => {
    'installDir': installDir,
    if (extra.isNotEmpty) 'extra': extra,
  };

  @override
  int get exitCode => ExitCode.ok;

  @override
  String? toText() =>
      'Uninstalled. Restart your terminal to apply PATH changes.';
}

class UninstallCommand implements Command<UninstallInput, UninstallOutput> {
  UninstallCommand(this.input, {required this.config, PlatformOps? platformOps})
    : platformOps =
          platformOps ??
          PlatformOps.current(
            executable: config.executable,
            assets: config.assets,
            postInstallArguments: config.postInstallArguments,
          );

  @override
  final UninstallInput input;

  final CliInstallationConfig config;
  final PlatformOps platformOps;

  @override
  String? validate() => null;

  /// Any [CliInstallationConfig.preUninstallSteps] first, then PATH, then
  /// the directory.
  ///
  /// The last two are not cosmetic: unsetting PATH after scheduling the
  /// deletion would leave a window in which the entry points at a directory
  /// already on its way out.
  @override
  Future<List<Step>> steps() async {
    final installDir = input.installDir;
    return [
      ...?config.preUninstallSteps?.call(installDir, platformOps),
      UnsetFromPath(
        platformOps: platformOps,
        binDir: p.join(installDir, 'bin'),
      ),
      DeleteInstallation(platformOps: platformOps, installDir: installDir),
    ];
  }

  @override
  UninstallOutput describe(Execution execution) {
    final extra = execution.outcomes
        .where((o) => o.verb != 'unset' && o.verb != 'delete')
        .map(
          (o) => {
            'verb': o.verb,
            'target': o.target,
            if (o.detail != null) 'detail': o.detail,
            if (o.values.isNotEmpty) 'values': o.values,
          },
        )
        .toList();
    return UninstallOutput(installDir: input.installDir, extra: extra);
  }
}
