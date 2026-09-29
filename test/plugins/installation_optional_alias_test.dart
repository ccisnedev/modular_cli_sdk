/// `CliInstallationConfig.alias` optional (issue #35, item 1).
///
/// Without an alias, `upgrade` and `uninstall` still build a plan and still
/// apply it: neither command touched the alias shim even when one was
/// configured (that remains each CLI's own install script's job, see
/// docs/installation-parity.md), so there is nothing an absent alias needs
/// to change there. What does change is the `release` doctor check's
/// message: it names [CliInstallationConfig.executable] instead.
///
/// With an alias configured, behavior stays identical to 0.8.0
/// (`installation_plugin_test.dart` already covers that unchanged).
library;

import 'dart:io';

import 'package:modular_cli_sdk/modular_cli_sdk.dart';
import 'package:modular_cli_sdk/testing.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../doubles.dart';
import 'installation_doubles.dart';

final String _platformAsset = const {
  'linux': 'cx-linux',
  'macos': 'cx-macos',
  'windows': 'cx-windows.exe',
}[Platform.operatingSystem]!;

void main() {
  test('alias defaults to null: a CLI with none can build the config', () {
    const config = CliInstallationConfig(
      repository: 'ccisnedev/docmd',
      executable: 'docmd',
      assets: {'linux': 'docmd-linux', 'windows': 'docmd-windows.exe'},
    );

    expect(config.alias, isNull);
  });

  group('upgrade with no alias', () {
    test('still plans the replacement', () async {
      final previews = await previewCommand(
        _upgradeCommand(
          releases: [_release('v9.9.9', asset: _platformAsset)],
        ),
      );

      expect(previews.map((p) => p.verb).toList(), ['replace']);
    });

    test('still applies: downloads and installs the newer release', () async {
      final downloader = FakeDownloader();
      final ops = FakePlatformOps();
      final installDir = Directory.systemTemp.createTempSync(
        'sdk_upgrade_noalias_',
      );
      addTearDown(() {
        if (installDir.existsSync()) installDir.deleteSync(recursive: true);
      });
      final binary = File(p.join(installDir.path, 'bin', 'cx.exe'))
        ..createSync(recursive: true)
        ..writeAsStringSync('outgoing');

      final output = await applyCommand(
        _upgradeCommand(
          releases: [_release('v9.9.9', asset: _platformAsset)],
          downloader: downloader,
          platformOps: ops,
          installDir: installDir.path,
          runningExecutable: binary.path,
        ),
      );

      expect(output.upgraded, isTrue);
      expect(downloader.requested, isNotEmpty);
      expect(ops.calls, contains(contains('expandArchive')));
    });

    test('no alias shim call is made: PlatformOps exposes none for it, '
        'with or without an alias configured', () async {
      final withAlias = FakePlatformOps();
      final withoutAlias = FakePlatformOps();

      await applyCommand(
        _upgradeCommand(
          releases: [_release('v9.9.9', asset: _platformAsset)],
          platformOps: withAlias,
          alias: 'calculatrix',
        ),
      );
      await applyCommand(
        _upgradeCommand(
          releases: [_release('v9.9.9', asset: _platformAsset)],
          platformOps: withoutAlias,
        ),
      );

      // Same shape of calls either way: nothing alias-specific was ever
      // called, so an absent alias changes nothing about what PlatformOps is
      // asked to do.
      expect(
        withoutAlias.calls.map(_callName),
        withAlias.calls.map(_callName),
      );
    });
  });

  group('uninstall with no alias', () {
    test('still plans unset then delete, nothing alias-related', () async {
      final previews = await previewCommand(
        _uninstallCommand(installDir: '/fake/dir'),
      );

      expect(previews.map((p) => p.verb).toList(), ['unset', 'delete']);
    });

    test('still applies: PATH and directory are touched', () async {
      final tempDir = Directory.systemTemp.createTempSync(
        'sdk_uninstall_noalias_',
      );
      addTearDown(() {
        if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
      });
      final ops = FakePlatformOps();

      await applyCommand(
        _uninstallCommand(installDir: tempDir.path, platformOps: ops),
      );

      expect(ops.calls, contains('scheduleDeletion(${tempDir.path})'));
    });

    test('no alias shim call is made, with or without an alias', () async {
      final withAlias = FakePlatformOps();
      final withoutAlias = FakePlatformOps();

      await applyCommand(
        _uninstallCommand(
          installDir: '/fake/dir',
          platformOps: withAlias,
          alias: 'calculatrix',
        ),
      );
      await applyCommand(
        _uninstallCommand(installDir: '/fake/dir', platformOps: withoutAlias),
      );

      expect(
        withoutAlias.calls.map(_callName),
        withAlias.calls.map(_callName),
      );
    });
  });

  group('doctor "release" check with no alias', () {
    test('names the executable, not an alias, in the upgrade hint', () async {
      final cli =
          ModularCli(suggestionDistance: 2, name: 'cx', version: '1.0.0')
            ..plugin(const DoctorPlugin())
            ..plugin(
              InstallationPlugin(
                config: CliInstallationConfig(
                  repository: 'ccisnedev/calculatrix',
                  executable: 'cx',
                  assets: const {
                    'linux': 'cx-linux',
                    'windows': 'cx-windows.exe',
                  },
                ),
                releaseSource: FakeReleaseSource(
                  releases: [_release('v9.9.9', asset: _platformAsset)],
                ),
                platformOps: FakePlatformOps(assetName: _platformAsset),
              ),
            );

      final out = MemorySink();
      final code = await cli.run(['doctor'], stdout: out);

      expect(code, ExitCode.ok);
      expect(
        out.output,
        contains('Run "cx upgrade --apply" to install it.'),
      );
      expect(out.output, isNot(contains('Run "calculatrix')));
    });
  });
}

String _callName(String call) => call.split('(').first;

CliRelease _release(
  String tag, {
  required String asset,
  String url = 'https://dl/asset',
}) => CliRelease(
  tagName: tag,
  assets: [CliReleaseAsset(name: asset, downloadUrl: url)],
);

CliInstallationConfig _config({String? alias}) => CliInstallationConfig(
  repository: 'ccisnedev/calculatrix',
  executable: 'cx',
  alias: alias,
  assets: const {'linux': 'cx-linux', 'windows': 'cx-windows.exe'},
);

UpgradeCommand _upgradeCommand({
  List<CliRelease> releases = const [],
  FakeReleaseSource? releaseSource,
  FakeDownloader? downloader,
  FakePlatformOps? platformOps,
  String installDir = '/fake/dir',
  String runningExecutable = '/fake/dir/bin/never-touched',
  String? alias,
}) => UpgradeCommand(
  UpgradeInput(installDir: installDir),
  config: _config(alias: alias),
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
  String? alias,
}) => UninstallCommand(
  UninstallInput(installDir: installDir),
  config: _config(alias: alias),
  platformOps: platformOps ?? FakePlatformOps(),
);
