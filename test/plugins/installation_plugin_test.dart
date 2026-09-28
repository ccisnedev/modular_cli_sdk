/// `InstallationPlugin`: `upgrade` / `uninstall`, and the doctor check it
/// contributes (`release`). Every network and platform access goes through a
/// fake from `installation_doubles.dart`: nothing here downloads a real
/// archive, extracts one, or touches a real PATH.
///
/// Ported from macss's and inquiry's own `upgrade_test.dart`/
/// `uninstall_test.dart` (`code/cli/test/` in each), adapted only in names
/// and config, plus new tests for the `release` doctor check this plugin
/// contributes. Only Windows and Linux are supported: macOS, and the
/// `binary`/`alias` doctor checks, were removed before 0.8.0 shipped. See
/// docs/installation-parity.md.
library;

import 'dart:convert';
import 'dart:io';

import 'package:modular_cli_sdk/modular_cli_sdk.dart';
import 'package:modular_cli_sdk/testing.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../doubles.dart';
import 'installation_doubles.dart';

/// The asset name for whatever platform these tests actually run on —
/// asset lookup is keyed by `Platform.operatingSystem` in production
/// (`assetForPlatform` in `cli_release_source.dart`), so a release's asset
/// must be named for the real platform running the suite, not a hardcoded
/// one. Kept in sync with every `assets` map this file builds.
final String _platformAsset = const {
  'linux': 'cx-linux',
  'macos': 'cx-macos',
  'windows': 'cx-windows.exe',
}[Platform.operatingSystem]!;

void main() {
  group('latestTaggedRelease', () {
    test('picks the newest tag matching the prefix', () {
      final releases = [
        const CliRelease(tagName: 'cli-v1.0.0', assets: []),
        const CliRelease(tagName: 'cli-v1.2.0', assets: []),
        const CliRelease(tagName: 'cli-v1.1.0', assets: []),
      ];
      expect(latestTaggedRelease(releases, 'cli-v')?.tagName, 'cli-v1.2.0');
    });

    test('ignores tags for a different product in the same repository', () {
      final releases = [
        const CliRelease(tagName: 'v9.9.9', assets: []),
        const CliRelease(tagName: 'cli-v1.0.0', assets: []),
      ];
      expect(latestTaggedRelease(releases, 'cli-v')?.tagName, 'cli-v1.0.0');
    });

    test(
      'a tag matching the prefix but not parsing as semver is surfaced, not skipped',
      () {
        final releases = [
          const CliRelease(tagName: 'cli-vnightly', assets: []),
          const CliRelease(tagName: 'cli-v1.0.0', assets: []),
        ];
        expect(
          () => latestTaggedRelease(releases, 'cli-v'),
          throwsA(
            isA<CliInvalidReleaseTag>().having(
              (e) => e.tagName,
              'tagName',
              'cli-vnightly',
            ),
          ),
        );
      },
    );

    test('returns null when nothing matches the prefix', () {
      final releases = [const CliRelease(tagName: 'v9.9.9', assets: [])];
      expect(latestTaggedRelease(releases, 'cli-v'), isNull);
    });
  });

  group('ReplaceInstallation says what it is doing while it does it', () {
    // Ported from macss's "macss upgrade says what it is doing while it does
    // it" group in code/cli/test/upgrade_test.dart. Replacing an installation
    // takes seconds and several megabytes: the plan says what *will* happen,
    // this says what *is* happening, and it is the only thing on the
    // terminal until the step finishes.
    late Directory root;
    late MemorySink progress;
    late FakePlatformOps ops;

    setUp(() {
      root = Directory.systemTemp.createTempSync('sdk_upgrade_progress_');
      progress = MemorySink();
      ops = FakePlatformOps();
    });

    tearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    /// A stand-in for the binary being replaced.
    ///
    /// **Never `Platform.resolvedExecutable`.** Under `dart test` that is the
    /// Dart VM, and the Windows branch of this step renames the running
    /// executable aside.
    late String fakeBinary;

    Future<String> replace({bool verifyAfterInstall = true}) async {
      fakeBinary = p.join(root.path, 'bin', 'cx.exe');
      File(fakeBinary)
        ..createSync(recursive: true)
        ..writeAsStringSync('the outgoing binary');

      await ReplaceInstallation(
        platformOps: ops,
        installDir: p.join(root.path, 'install'),
        from: '1.0.0',
        to: '1.1.0',
        asset: 'cx-windows.zip',
        downloadUrl: 'https://example.invalid/cx-windows.zip',
        verifyAfterInstall: verifyAfterInstall,
        downloader: (url, destination) async =>
            File(destination).writeAsStringSync('an archive'),
        progress: progress,
        runningExecutable: fakeBinary,
      ).perform(StepContext(const {}));
      return progress.output;
    }

    test('names the asset and the versions before it downloads', () async {
      final said = await replace();

      expect(said, contains('Downloading cx-windows.zip'));
      expect(said, contains('1.0.0'));
      expect(said, contains('1.1.0'));
    });

    test('says when it extracts, and where', () async {
      final said = await replace();

      expect(said, contains('Extracting into'));
      expect(said, contains(p.join(root.path, 'install')));
    });

    test('in the order the work happens', () async {
      final said = await replace();

      expect(said.indexOf('Downloading'), lessThan(said.indexOf('Extracting')));
      expect(said.indexOf('Extracting'), lessThan(said.indexOf('Verifying')));
    });

    // Ported from macss's own "says when it verifies" test
    // (code/cli/test/upgrade_test.dart): macss's `ReplaceInstallation` runs
    // the freshly extracted binary inline, unconditionally, right after
    // extraction — not from a `postUpgradeSteps` callback a CLI might leave
    // unset.
    test('says when it verifies, by default (matching macss)', () async {
      expect(await replace(), contains('Verifying installation'));
    });

    test('calls runPostInstall with the install directory', () async {
      await replace();

      expect(
        ops.calls,
        contains('runPostInstall(${p.join(root.path, 'install')})'),
      );
    });

    // macss's own `runPostInstall` never inspects the child's exit code, but
    // nothing catches a failure to even launch it (a missing binary throws
    // `ProcessException`) — which is what makes the check a hard failure in
    // practice, not a check whose result is silently discarded.
    test(
      'a failed verification fails the upgrade, hard-fail like macss',
      () async {
        ops = FakePlatformOps(runPostInstallError: Exception('no such file'));

        expect(() => replace(), throwsA(isA<Exception>()));
      },
    );

    // The one case where macss's own behavior is not what a CLI wants:
    // inquiry verifies leniently, from its own `postUpgradeSteps` step
    // (`RedeployHosts`), and must not also run the hard-fail check inline.
    test('verifyAfterInstall: false skips verification entirely', () async {
      final said = await replace(verifyAfterInstall: false);

      expect(said, isNot(contains('Verifying')));
      expect(ops.calls.any((c) => c.startsWith('runPostInstall')), isFalse);
    });

    test('moves the outgoing binary aside and cleans it up', () async {
      await replace();

      expect(
        File(fakeBinary).existsSync(),
        isFalse,
        reason: 'it was moved aside to make room for the new one',
      );
      expect(
        File('$fakeBinary.bak').existsSync(),
        isFalse,
        reason: 'and the backup is not left behind',
      );
    }, testOn: 'windows');

    test(
      'calls expandArchive with the downloaded archive and installDir',
      () async {
        await replace();

        // The archive is downloaded into its own throwaway temp directory
        // (cleaned up once perform() returns), not into installDir itself —
        // only the extraction destination is installDir. The temp directory's
        // exact name is randomized by createTempSync, so this matches on the
        // asset name and the destination rather than the full source path.
        final call = ops.calls.singleWhere(
          (c) => c.startsWith('expandArchive('),
        );
        expect(call, contains('cx-windows.zip'));
        expect(call, endsWith(', ${p.join(root.path, 'install')})'));
      },
    );
  });

  group('UpgradeInput / UpgradeOutput', () {
    test('UpgradeInput serializes correctly', () {
      final input = UpgradeInput(installDir: '/fake/dir');
      expect(input.toJson(), {'installDir': '/fake/dir'});
    });

    test('UpgradeOutput reports no upgrade when already latest', () {
      final output = UpgradeOutput(
        previousVersion: '1.0.0',
        newVersion: '1.0.0',
        upgraded: false,
        reason: 'Already on the latest version',
      );
      expect(output.exitCode, ExitCode.ok);
      expect(output.upgraded, isFalse);
      expect(output.toJson()['reason'], contains('latest'));
    });

    test('UpgradeOutput reports successful upgrade', () {
      final output = UpgradeOutput(
        previousVersion: '0.0.1',
        newVersion: '0.0.2',
        upgraded: true,
      );
      expect(output.exitCode, ExitCode.ok);
      expect(output.upgraded, isTrue);
      expect(output.previousVersion, '0.0.1');
      expect(output.newVersion, '0.0.2');
    });

    test('toText returns checkmark message when upgraded', () {
      final output = UpgradeOutput(
        previousVersion: '0.0.1',
        newVersion: '0.0.2',
        upgraded: true,
      );
      expect(output.toText(), contains('✓'));
      expect(output.toText(), contains('0.0.1'));
      expect(output.toText(), contains('0.0.2'));
    });

    test('toText returns plain message when not upgraded', () {
      final output = UpgradeOutput(
        previousVersion: '1.0.0',
        newVersion: '1.0.0',
        upgraded: false,
        reason: 'Already on the latest version',
      );
      expect(output.toText(), equals('Already on the latest version'));
    });
  });

  group('UpgradeCommand.steps() (--plan equivalent)', () {
    // Ported from inquiry's "inquiry upgrade under --plan" group: the
    // releases API is asked once while the plan is built, so the version, the
    // asset and the URL a person approves are exactly the ones that would be
    // downloaded.
    test('names the replacement, with version, asset and URL', () async {
      final previews = await previewCommand(
        _upgradeCommand(
          releases: [
            _release(
              'v9.9.9',
              asset: _platformAsset,
              url: 'https://example.test/asset',
            ),
          ],
        ),
      );

      expect(previews.map((p) => p.verb).toList(), ['replace']);
      expect(previews.first.detail, contains('1.0.0 → 9.9.9'));
      expect(previews.first.detail, contains(_platformAsset));
      expect(previews.first.detail, contains('https://example.test/'));
    });

    test('asks the releases API once, when the plan is built', () async {
      final releaseSource = FakeReleaseSource(
        releases: [_release('v9.9.9', asset: _platformAsset)],
      );

      await previewCommand(_upgradeCommand(releaseSource: releaseSource));

      expect(releaseSource.latestReleaseCalls, 1);
    });

    test('touches nothing under --plan: no download, no extraction', () async {
      final downloader = FakeDownloader();
      final ops = FakePlatformOps();

      await previewCommand(
        _upgradeCommand(
          releases: [_release('v9.9.9', asset: _platformAsset)],
          downloader: downloader,
          platformOps: ops,
        ),
      );

      expect(downloader.requested, isEmpty);
      expect(ops.calls, isEmpty);
    });

    test('plans nothing when already on the latest version', () async {
      final command = _upgradeCommand(
        releases: [_release('v1.0.0', asset: _platformAsset)],
      );

      expect(await previewCommand(command), isEmpty);

      final output = await applyCommand(command);
      expect(output.upgraded, isFalse);
      expect(output.toText(), contains('Already on the latest version'));
    });

    test('plans nothing when the repository has no releases', () async {
      final command = _upgradeCommand(releases: const []);

      expect(await previewCommand(command), isEmpty);

      final output = await applyCommand(command);
      expect(output.upgraded, isFalse);
      expect(output.reason, contains('no releases'));
    });

    test('skips a prerelease latest release rather than offering it', () async {
      // macss's own check: the tagPrefix-absent path (the one both CLIs
      // actually use) skips a prerelease latest release.
      final command = _upgradeCommand(
        releases: [
          CliRelease(
            tagName: 'v9.9.9',
            prerelease: true,
            assets: [
              CliReleaseAsset(
                name: _platformAsset,
                downloadUrl: 'https://dl/x',
              ),
            ],
          ),
        ],
      );

      final output = await applyCommand(command);
      expect(output.upgraded, isFalse);
      expect(output.reason, contains('prerelease'));
    });

    test('refuses a release that carries no asset for this platform', () async {
      final command = _upgradeCommand(
        releases: [_release('v9.9.9', asset: 'some-other-platform.zip')],
      );

      expect(
        () => previewCommand(command),
        throwsA(
          isA<CommandException>().having((e) => e.id, 'id', 'asset-not-found'),
        ),
      );
    });

    test('a failed release lookup throws a structured error', () async {
      final command = _upgradeCommand(
        releaseSource: FakeReleaseSource(
          error: const CliReleaseLookupFailure('no network'),
        ),
      );

      expect(
        () => previewCommand(command),
        throwsA(
          isA<CommandException>().having(
            (e) => e.id,
            'id',
            'release-lookup-failed',
          ),
        ),
      );
    });

    test(
      'a release tag that does not parse as semver throws a structured error naming the tag',
      () async {
        final command = _upgradeCommand(
          tagPrefix: 'cli-v',
          releases: [_release('cli-vnightly', asset: _platformAsset)],
        );

        expect(
          () => previewCommand(command),
          throwsA(
            isA<CommandException>()
                .having((e) => e.id, 'id', 'release-lookup-failed')
                .having((e) => e.message, 'message', contains('cli-vnightly')),
          ),
        );
      },
    );

    test(
      'with a tagPrefix, asks listReleases rather than latestRelease',
      () async {
        final releaseSource = FakeReleaseSource(
          releases: [_release('cli-v1.1.0', asset: _platformAsset)],
        );

        await previewCommand(
          _upgradeCommand(tagPrefix: 'cli-v', releaseSource: releaseSource),
        );

        expect(releaseSource.listReleasesCalls, 1);
        expect(releaseSource.latestReleaseCalls, 0);
      },
    );

    test(
      'includes any postUpgradeSteps after the replace step, built from the '
      'install directory and the platform ops the upgrade itself used',
      () async {
        final ops = FakePlatformOps();
        List<String>? seenInstallDir;
        PlatformOps? seenOps;
        final command = _upgradeCommand(
          releases: [_release('v9.9.9', asset: _platformAsset)],
          platformOps: ops,
          postUpgradeSteps: (installDir, platformOps) {
            seenInstallDir = [installDir];
            seenOps = platformOps;
            return [FakeStep(verb: 'deploy', target: 'hosts')];
          },
        );

        final previews = await previewCommand(command);

        expect(previews.map((p) => p.verb).toList(), ['replace', 'deploy']);
        expect(seenInstallDir, isNotNull);
        expect(seenOps, same(ops));
      },
    );

    test('reports postUpgradeSteps outcomes generically under extra, not '
        'folded into whether the upgrade itself happened', () async {
      final installDir = Directory.systemTemp.createTempSync(
        'sdk_upgrade_extra_',
      );
      addTearDown(() {
        if (installDir.existsSync()) installDir.deleteSync(recursive: true);
      });
      final binary = File(p.join(installDir.path, 'bin', 'cx.exe'))
        ..createSync(recursive: true)
        ..writeAsStringSync('outgoing');

      final command = _upgradeCommand(
        releases: [_release('v9.9.9', asset: _platformAsset)],
        downloader: FakeDownloader(),
        installDir: installDir.path,
        runningExecutable: binary.path,
        postUpgradeSteps: (installDir, platformOps) => [
          FakeStep(verb: 'deploy', target: 'hosts'),
        ],
      );

      final output = await applyCommand(command);

      expect(output.upgraded, isTrue);
      expect(output.extra, [
        {'verb': 'deploy', 'target': 'hosts'},
      ]);
    });
  });

  group('UpgradeCommand under --apply', () {
    test('downloads and installs the newer release', () async {
      final downloader = FakeDownloader();
      final ops = FakePlatformOps();
      final installDir = Directory.systemTemp.createTempSync(
        'sdk_upgrade_apply_',
      );
      addTearDown(() {
        if (installDir.existsSync()) installDir.deleteSync(recursive: true);
      });
      final binary = File(p.join(installDir.path, 'bin', 'cx.exe'))
        ..createSync(recursive: true)
        ..writeAsStringSync('outgoing');

      final output = await applyCommand(
        _upgradeCommand(
          releases: [
            _release('v9.9.9', asset: _platformAsset, url: 'https://dl/asset'),
          ],
          downloader: downloader,
          platformOps: ops,
          installDir: installDir.path,
          runningExecutable: binary.path,
        ),
      );

      expect(output.upgraded, isTrue);
      expect(output.newVersion, '9.9.9');
      expect(downloader.requested, ['https://dl/asset']);
      final call = ops.calls.singleWhere((c) => c.startsWith('expandArchive('));
      expect(call, contains(_platformAsset));
      expect(call, endsWith(', ${installDir.path})'));
      // Verification runs by default, matching macss: this config sets no
      // `verifyAfterInstall`, so `CliInstallationConfig`'s own default (true)
      // must have carried all the way from the config to the step.
      expect(ops.calls, contains('runPostInstall(${installDir.path})'));
    });

    test(
      'a download failure propagates rather than installing anything',
      () async {
        final ops = FakePlatformOps();
        final installDir = Directory.systemTemp.createTempSync(
          'sdk_upgrade_fail_',
        );
        addTearDown(() {
          if (installDir.existsSync()) installDir.deleteSync(recursive: true);
        });
        final binary = File(p.join(installDir.path, 'bin', 'cx.exe'))
          ..createSync(recursive: true)
          ..writeAsStringSync('outgoing');

        final command = _upgradeCommand(
          releases: [_release('v9.9.9', asset: _platformAsset)],
          downloader: FakeDownloader(error: Exception('connection reset')),
          platformOps: ops,
          installDir: installDir.path,
          runningExecutable: binary.path,
        );

        final execution = await runCommand(command);
        expect(execution.failure, isNotNull);
        expect(
          ops.calls,
          isEmpty,
          reason: 'the download failed before extraction',
        );
      },
    );
  });

  group('UninstallInput / UninstallOutput', () {
    test('UninstallInput serializes correctly', () {
      final input = UninstallInput(installDir: '/fake/dir');
      expect(input.toJson(), {'installDir': '/fake/dir'});
    });

    test('exits ok and confirms uninstall', () {
      final output = UninstallOutput(installDir: '/fake/dir');
      expect(output.exitCode, ExitCode.ok);
      expect(output.toText(), contains('Uninstalled'));
    });
  });

  group('UninstallCommand.steps() (--plan equivalent)', () {
    test('names the two steps, PATH first and the directory last', () async {
      final previews = await previewCommand(
        _uninstallCommand(installDir: '/fake/dir'),
      );

      expect(previews.map((p) => p.verb).toList(), ['unset', 'delete']);
    });

    test('says the installation directory it would delete', () async {
      final previews = await previewCommand(
        _uninstallCommand(installDir: '/fake/dir'),
      );

      final delete = previews.firstWhere((p) => p.verb == 'delete');
      expect(delete.target, '/fake/dir');
      expect(delete.detail, contains('not touched'));
    });

    test('includes any preUninstallSteps first, built from the install '
        'directory and the platform ops the uninstall itself used', () async {
      final ops = FakePlatformOps();
      final previews = await previewCommand(
        _uninstallCommand(
          installDir: '/fake/dir',
          platformOps: ops,
          preUninstallSteps: (installDir, platformOps) => [
            FakeStep(verb: 'clean', target: 'hosts'),
          ],
        ),
      );

      expect(previews.map((p) => p.verb).toList(), [
        'clean',
        'unset',
        'delete',
      ]);
    });
  });

  group('UninstallCommand under --apply', () {
    test('removes bin dir from PATH when present', () async {
      final tempDir = Directory.systemTemp.createTempSync('sdk_uninstall_');
      addTearDown(() {
        if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
      });
      final binDir = p.join(tempDir.path, 'bin');
      final sep = Platform.isWindows ? ';' : ':';
      const otherA = '/other';
      const otherB = '/more';
      final ops = FakePlatformOps(
        fakeEnvValue: '$otherA$sep$binDir$sep$otherB',
      );

      await applyCommand(
        _uninstallCommand(installDir: tempDir.path, platformOps: ops),
      );

      expect(ops.calls, contains('getEnvVariable(PATH)'));
      expect(ops.calls, contains('setEnvVariable(PATH, $otherA$sep$otherB)'));
    });

    test('does not call setEnvVariable when bin dir not in PATH', () async {
      final tempDir = Directory.systemTemp.createTempSync('sdk_uninstall_');
      addTearDown(() {
        if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
      });
      final sep = Platform.isWindows ? ';' : ':';
      final ops = FakePlatformOps(fakeEnvValue: '/other${sep}more');

      await applyCommand(
        _uninstallCommand(installDir: tempDir.path, platformOps: ops),
      );

      expect(ops.calls, contains('getEnvVariable(PATH)'));
      expect(ops.calls.where((c) => c.startsWith('setEnvVariable')), isEmpty);
    });

    test('schedules deletion of the install directory', () async {
      final tempDir = Directory.systemTemp.createTempSync('sdk_uninstall_');
      addTearDown(() {
        if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
      });
      final ops = FakePlatformOps();

      await applyCommand(
        _uninstallCommand(installDir: tempDir.path, platformOps: ops),
      );

      expect(ops.calls, contains('scheduleDeletion(${tempDir.path})'));
    });

    test(
      'reports preUninstallSteps outcomes generically under extra',
      () async {
        final tempDir = Directory.systemTemp.createTempSync('sdk_uninstall_');
        addTearDown(() {
          if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
        });

        final output = await applyCommand(
          _uninstallCommand(
            installDir: tempDir.path,
            preUninstallSteps: (installDir, platformOps) => [
              FakeStep(verb: 'clean', target: 'hosts'),
            ],
          ),
        );

        expect(output.extra, [
          {'verb': 'clean', 'target': 'hosts'},
        ]);
      },
    );
  });

  group('doctor checks contributed by InstallationPlugin', () {
    // `binary` and `alias` were removed before 0.8.0 shipped: see
    // https://github.com/ccisnedev/modular_cli_sdk/issues (linked from
    // docs/installation-parity.md) for what they checked and why they were
    // deferred. `release` is the only check this plugin contributes now.
    test('contributes exactly one check, named "release"', () async {
      final cli = _cliWith(
        _plugin(releases: [_release('v1.0.0', asset: _platformAsset)]),
      );

      final out = MemorySink();
      final code = await cli.run(['doctor', '--json'], stdout: out);

      expect(code, ExitCode.ok);
      final decoded = jsonDecode(out.output) as Map<String, dynamic>;
      final checks = decoded['checks'] as List;
      expect(checks.map((c) => c['name']).toList(), ['release']);
    });

    test('up to date is ok, not a warning', () async {
      final cli = _cliWith(
        _plugin(releases: [_release('v1.0.0', asset: _platformAsset)]),
      );

      final out = MemorySink();
      final code = await cli.run(['doctor'], stdout: out);

      expect(code, ExitCode.ok);
      expect(out.output, contains('Up to date'));
    });

    test('a newer release is a warning, not an error', () async {
      final cli = _cliWith(
        _plugin(releases: [_release('v9.9.9', asset: _platformAsset)]),
      );

      final out = MemorySink();
      final code = await cli.run(['doctor'], stdout: out);

      expect(code, ExitCode.ok);
      expect(out.output, contains('warning'));
      expect(
        out.output,
        contains(
          'A newer release is available: v9.9.9 (current: 1.0.0). '
          'Run "calculatrix upgrade --apply" to install it.',
        ),
      );
    });

    test(
      'a release tag that does not parse as semver is a doctor warning naming the tag',
      () async {
        final cli = _cliWith(
          _plugin(
            tagPrefix: 'cli-v',
            releases: [_release('cli-vnightly', asset: _platformAsset)],
          ),
        );

        final out = MemorySink();
        final code = await cli.run(['doctor'], stdout: out);

        expect(code, ExitCode.ok);
        expect(out.output, contains('warning'));
        expect(out.output, contains('cli-vnightly'));
      },
    );

    test('a failed release lookup is a warning, not an error', () async {
      final cli = _cliWith(
        _plugin(releaseError: const CliReleaseLookupFailure('no network')),
      );

      final out = MemorySink();
      final code = await cli.run(['doctor'], stdout: out);

      expect(code, ExitCode.ok);
      expect(out.output, contains('warning'));
    });

    test('a repository with no releases is a doctor warning', () async {
      final cli = _cliWith(_plugin(releases: const []));

      final out = MemorySink();
      final code = await cli.run(['doctor'], stdout: out);

      expect(code, ExitCode.ok);
      expect(out.output, contains('warning'));
      expect(out.output, contains('has no releases'));
    });
  });
}

CliInstallationConfig _config({
  String? tagPrefix,
  List<Step> Function(String installDir, PlatformOps platformOps)?
  postUpgradeSteps,
}) => CliInstallationConfig(
  repository: 'ccisnedev/calculatrix',
  tagPrefix: tagPrefix,
  executable: 'cx',
  alias: 'calculatrix',
  assets: const {'linux': 'cx-linux', 'windows': 'cx-windows.exe'},
  postUpgradeSteps: postUpgradeSteps,
);

CliRelease _release(
  String tag, {
  required String asset,
  String url = 'https://dl/asset',
}) => CliRelease(
  tagName: tag,
  assets: [CliReleaseAsset(name: asset, downloadUrl: url)],
);

UpgradeCommand _upgradeCommand({
  String? tagPrefix,
  List<CliRelease> releases = const [],
  FakeReleaseSource? releaseSource,
  FakeDownloader? downloader,
  FakePlatformOps? platformOps,
  String installDir = '/fake/dir',
  String runningExecutable = '/fake/dir/bin/never-touched',
  List<Step> Function(String installDir, PlatformOps platformOps)?
  postUpgradeSteps,
}) => UpgradeCommand(
  UpgradeInput(installDir: installDir),
  config: _config(tagPrefix: tagPrefix, postUpgradeSteps: postUpgradeSteps),
  currentVersion: '1.0.0',
  releaseSource: releaseSource ?? FakeReleaseSource(releases: releases),
  platformOps: platformOps ?? FakePlatformOps(),
  downloader: downloader?.call,
  progress: MemorySink(),
  runningExecutable: runningExecutable,
);

UninstallCommand _uninstallCommand({
  required String installDir,
  FakePlatformOps? platformOps,
  List<Step> Function(String installDir, PlatformOps platformOps)?
  preUninstallSteps,
}) => UninstallCommand(
  UninstallInput(installDir: installDir),
  config: CliInstallationConfig(
    repository: 'ccisnedev/calculatrix',
    executable: 'cx',
    alias: 'calculatrix',
    assets: const {'linux': 'cx-linux', 'windows': 'cx-windows.exe'},
    preUninstallSteps: preUninstallSteps,
  ),
  platformOps: platformOps ?? FakePlatformOps(),
);

InstallationPlugin _plugin({
  String? tagPrefix,
  List<CliRelease> releases = const [],
  Object? releaseError,
}) => InstallationPlugin(
  config: CliInstallationConfig(
    repository: 'ccisnedev/calculatrix',
    tagPrefix: tagPrefix,
    executable: 'cx',
    alias: 'calculatrix',
    assets: const {'linux': 'cx-linux', 'windows': 'cx-windows.exe'},
  ),
  releaseSource: FakeReleaseSource(releases: releases, error: releaseError),
  platformOps: FakePlatformOps(assetName: _platformAsset),
);

ModularCli _cliWith(InstallationPlugin plugin) =>
    ModularCli(suggestionDistance: 2, name: 'cx', version: '1.0.0')
      ..plugin(const DoctorPlugin())
      ..plugin(plugin);
