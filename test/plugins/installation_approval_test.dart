/// `upgrade` and `uninstall` are ordinary commands: `--apply` goes through
/// the normal interactive approval gate unless `--autoapprove` is given,
/// exactly as macss's and inquiry's own `upgrade`/`uninstall` do (neither
/// implements anything like `SkipsInteractiveApproval`). See
/// `docs/installation-parity.md`.
///
/// These drive a real [ModularCli] end to end (`cli.run(...)`), not
/// [applyCommand]: `applyCommand` performs a command's steps directly and
/// never reaches the approval gate in `ModuleBuilder` at all, so it cannot
/// tell a command that is asked and approved from one that was never asked
/// in the first place. Only a real run through the CLI can.
library;

import 'dart:io';

import 'package:modular_cli_sdk/modular_cli_sdk.dart';
import 'package:test/test.dart';

import '../doubles.dart';
import 'installation_doubles.dart';

/// Kept in sync with the platform this suite actually runs on, exactly as
/// installation_plugin_test.dart's own `_platformAsset` is.
final String _platformAsset = const {
  'linux': 'cx-linux',
  'macos': 'cx-macos',
  'windows': 'cx-windows.exe',
}[Platform.operatingSystem]!;

void main() {
  group('upgrade --apply', () {
    test(
      'a refusing approver performs no mutation: no download, no extraction',
      () async {
        final downloader = FakeDownloader();
        final ops = FakePlatformOps(assetName: _platformAsset);
        final cli = _cliWithUpgrade(
          upgrade: _upgradeCommand(
            releases: [_release('v9.9.9', asset: _platformAsset)],
            downloader: downloader,
            platformOps: ops,
          ),
          approver: (_) async => false,
        );

        final err = MemorySink();
        final code = await cli.run(['upgrade', '--apply'], stderr: err);

        expect(downloader.requested, isEmpty);
        expect(ops.calls, isEmpty);
        expect(code, isNot(ExitCode.ok));
      },
    );

    test('with --autoapprove it proceeds', () async {
      // A real file stands in for the running executable: on Windows,
      // ReplaceInstallation renames it aside before extracting, and that
      // rename is not faked, only PlatformOps and the download are.
      final root = Directory.systemTemp.createTempSync('sdk_upgrade_apply_');
      addTearDown(() {
        if (root.existsSync()) root.deleteSync(recursive: true);
      });
      final runningExecutable = File(
        '${root.path}${Platform.pathSeparator}cx.exe',
      )..writeAsStringSync('the outgoing binary');

      final downloader = FakeDownloader();
      final ops = FakePlatformOps(assetName: _platformAsset);
      var asked = false;
      final cli = _cliWithUpgrade(
        upgrade: _upgradeCommand(
          releases: [_release('v9.9.9', asset: _platformAsset)],
          downloader: downloader,
          platformOps: ops,
          runningExecutable: runningExecutable.path,
        ),
        approver: (_) async {
          asked = true;
          return true;
        },
      );

      final out = MemorySink();
      final code = await cli.run([
        'upgrade',
        '--apply',
        '--autoapprove',
      ], stdout: out);

      expect(asked, isFalse);
      expect(downloader.requested, isNotEmpty);
      expect(ops.calls, contains(contains('expandArchive')));
      expect(code, ExitCode.ok);
    });
  });

  group('uninstall --apply', () {
    test('a refusing approver performs no mutation: no PATH change, no '
        'scheduled deletion', () async {
      final ops = FakePlatformOps();
      final cli = _cliWithUninstall(
        uninstall: _uninstallCommand(installDir: '/fake/dir', platformOps: ops),
        approver: (_) async => false,
      );

      final err = MemorySink();
      final code = await cli.run(['uninstall', '--apply'], stderr: err);

      expect(ops.calls, isEmpty);
      expect(code, isNot(ExitCode.ok));
    });

    test('with --autoapprove it proceeds', () async {
      final ops = FakePlatformOps();
      var asked = false;
      final cli = _cliWithUninstall(
        uninstall: _uninstallCommand(installDir: '/fake/dir', platformOps: ops),
        approver: (_) async {
          asked = true;
          return true;
        },
      );

      final out = MemorySink();
      final code = await cli.run([
        'uninstall',
        '--apply',
        '--autoapprove',
      ], stdout: out);

      expect(asked, isFalse);
      expect(ops.calls, isNotEmpty);
      expect(ops.calls.any((c) => c.startsWith('scheduleDeletion')), isTrue);
      expect(code, ExitCode.ok);
    });
  });
}

// ── Helpers ─────────────────────────────────────────────────────────────────

ModularCli _cliWithUpgrade({
  required UpgradeCommand upgrade,
  required Approver approver,
}) => ModularCli(approver: approver, suggestionDistance: 2)
  ..command<UpgradeInput, UpgradeOutput>(
    'upgrade',
    (req) => upgrade,
    globals: true,
    contract: CliContract.none,
  );

ModularCli _cliWithUninstall({
  required UninstallCommand uninstall,
  required Approver approver,
}) => ModularCli(approver: approver, suggestionDistance: 2)
  ..command<UninstallInput, UninstallOutput>(
    'uninstall',
    (req) => uninstall,
    globals: true,
    contract: CliContract.none,
  );

CliInstallationConfig _config() => const CliInstallationConfig(
  repository: 'ccisnedev/calculatrix',
  executable: 'cx',
  alias: 'calculatrix',
  assets: {'linux': 'cx-linux', 'windows': 'cx-windows.exe'},
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
  List<CliRelease> releases = const [],
  FakeDownloader? downloader,
  FakePlatformOps? platformOps,
  String installDir = '/fake/dir',
  String runningExecutable = '/fake/dir/bin/never-touched',
}) => UpgradeCommand(
  UpgradeInput(installDir: installDir),
  config: _config(),
  currentVersion: '1.0.0',
  releaseSource: FakeReleaseSource(releases: releases),
  platformOps: platformOps ?? FakePlatformOps(),
  downloader: downloader?.call,
  progress: MemorySink(),
  runningExecutable: runningExecutable,
);

UninstallCommand _uninstallCommand({
  required String installDir,
  FakePlatformOps? platformOps,
}) => UninstallCommand(
  UninstallInput(installDir: installDir),
  config: _config(),
  platformOps: platformOps ?? FakePlatformOps(),
);
