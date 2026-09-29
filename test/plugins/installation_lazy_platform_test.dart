/// Lazy platform resolution (issue #35, item 2).
///
/// `PlatformOps.current()` itself is unchanged (`cli_platform_ops_test.dart`
/// still covers it, `@TestOn('mac-os')`, throwing a plain `UnsupportedError`
/// for any OS neither Windows nor Linux). What changes is *when* the SDK
/// asks for it: never at `InstallationPlugin` construction, never for a
/// command other than `upgrade`/`uninstall`, and only once those actually
/// run does an OS with no configured release asset produce a clear,
/// structured `CommandException` (through the SDK's normal error/exit-code
/// path) rather than an uncaught error with a stack trace.
///
/// An OS with no configured release asset is simulated the same way on
/// whatever platform runs this suite: a `CliInstallationConfig.assets` map
/// that has no entry for `Platform.operatingSystem`. `PlatformOps.current()`
/// throws for that reason first, before ever branching on
/// `Platform.isWindows`/`Platform.isLinux`, so this exercises the exact
/// condition a real unsupported OS (say, macOS) would hit, deterministically,
/// on this suite's own platform.
library;

import 'dart:io';

import 'package:modular_cli_sdk/modular_cli_sdk.dart';
import 'package:modular_cli_sdk/testing.dart';
import 'package:test/test.dart';

import '../doubles.dart';
import 'installation_doubles.dart';

final String _platformAsset = const {
  'linux': 'cx-linux',
  'macos': 'cx-macos',
  'windows': 'cx-windows.exe',
}[Platform.operatingSystem]!;

/// Every asset entry except this suite's own OS: `PlatformOps.current()`
/// throws `UnsupportedError` for it regardless of which OS actually runs the
/// suite.
final Map<String, String> _noAssetForThisOS = {
  for (final os in ['linux', 'windows', 'macos'])
    if (os != Platform.operatingSystem) os: 'cx-$os',
};

void main() {
  group('InstallationPlugin construction', () {
    test('never resolves PlatformOps, even on an OS with no asset '
        'configured', () {
      expect(
        () => InstallationPlugin(
          config: CliInstallationConfig(
            repository: 'ccisnedev/calculatrix',
            executable: 'cx',
            assets: _noAssetForThisOS,
          ),
          releaseSource: FakeReleaseSource(),
        ),
        returnsNormally,
      );
    });
  });

  group('a non-installation command, on an OS with no asset configured', () {
    test('doctor still succeeds: it never touches PlatformOps', () async {
      final plugin = InstallationPlugin(
        config: CliInstallationConfig(
          repository: 'ccisnedev/calculatrix',
          executable: 'cx',
          assets: _noAssetForThisOS,
        ),
        releaseSource: FakeReleaseSource(
          releases: [_release('v1.0.0', asset: 'irrelevant')],
        ),
      );
      final cli =
          ModularCli(suggestionDistance: 2, name: 'cx', version: '1.0.0')
            ..plugin(const DoctorPlugin())
            ..plugin(plugin);

      final out = MemorySink();
      final code = await cli.run(['doctor'], stdout: out);

      expect(code, ExitCode.ok);
    });
  });

  group('upgrade on an OS with no asset configured', () {
    test(
      'fails with a structured, unsupported-platform CommandException, '
      'not the plain UnsupportedError PlatformOps.current() throws',
      () async {
        final command = UpgradeCommand(
          UpgradeInput(installDir: '/fake/dir'),
          config: CliInstallationConfig(
            repository: 'ccisnedev/calculatrix',
            executable: 'cx',
            assets: _noAssetForThisOS,
          ),
          currentVersion: '1.0.0',
          releaseSource: FakeReleaseSource(
            releases: [_release('v9.9.9', asset: 'cx-anything')],
          ),
        );

        await expectLater(
          () => previewCommand(command),
          throwsA(
            isA<CommandException>()
                .having((e) => e.id, 'id', 'platform-not-supported')
                .having((e) => e.exitCode, 'exitCode', ExitCode.configError),
          ),
        );
      },
    );

    test('through a real CLI run, exits with the unsupported-platform code, '
        'not a crash', () async {
      final plugin = InstallationPlugin(
        config: CliInstallationConfig(
          repository: 'ccisnedev/calculatrix',
          executable: 'cx',
          assets: _noAssetForThisOS,
        ),
        releaseSource: FakeReleaseSource(
          releases: [_release('v9.9.9', asset: 'cx-anything')],
        ),
      );
      final cli =
          ModularCli(suggestionDistance: 2, name: 'cx', version: '1.0.0')
            ..plugin(const DoctorPlugin())
            ..plugin(plugin);

      final err = MemorySink();
      final code = await cli.run(['upgrade', '--plan'], stderr: err);

      expect(code, ExitCode.configError);
      expect(err.output, contains('platform-not-supported'));
    });
  });

  group('uninstall on an OS with no asset configured', () {
    test('fails with the same structured CommandException', () async {
      final command = UninstallCommand(
        UninstallInput(installDir: '/fake/dir'),
        config: CliInstallationConfig(
          repository: 'ccisnedev/calculatrix',
          executable: 'cx',
          assets: _noAssetForThisOS,
        ),
      );

      await expectLater(
        () => previewCommand(command),
        throwsA(
          isA<CommandException>()
              .having((e) => e.id, 'id', 'platform-not-supported')
              .having((e) => e.exitCode, 'exitCode', ExitCode.configError),
        ),
      );
    });

    test('through a real CLI run, exits with the unsupported-platform code, '
        'not a crash', () async {
      final plugin = InstallationPlugin(
        config: CliInstallationConfig(
          repository: 'ccisnedev/calculatrix',
          executable: 'cx',
          assets: _noAssetForThisOS,
        ),
        releaseSource: FakeReleaseSource(),
      );
      final cli =
          ModularCli(suggestionDistance: 2, name: 'cx', version: '1.0.0')
            ..plugin(const DoctorPlugin())
            ..plugin(plugin);

      final err = MemorySink();
      final code = await cli.run(['uninstall', '--plan'], stderr: err);

      expect(code, ExitCode.configError);
      expect(err.output, contains('platform-not-supported'));
    });
  });

  group('injected PlatformOps keeps working, even with no asset configured '
      'for this OS', () {
    test('InstallationPlugin construction uses the injected fake, never '
        'PlatformOps.current()', () {
      final ops = FakePlatformOps();

      expect(
        () => InstallationPlugin(
          config: CliInstallationConfig(
            repository: 'ccisnedev/calculatrix',
            executable: 'cx',
            assets: _noAssetForThisOS,
          ),
          releaseSource: FakeReleaseSource(),
          platformOps: ops,
        ),
        returnsNormally,
      );
    });

    test('upgrade succeeds using the injected fake, on a config that does '
        'support this OS: an injected PlatformOps bypasses PlatformOps.current, '
        'nothing more, asset lookup is still config.assets doing its own, '
        'unrelated job', () async {
      final ops = FakePlatformOps();
      final installDir = Directory.systemTemp.createTempSync(
        'sdk_upgrade_lazy_',
      );
      addTearDown(() {
        if (installDir.existsSync()) installDir.deleteSync(recursive: true);
      });
      final binary =
          File(
              '${installDir.path}${Platform.pathSeparator}bin'
              '${Platform.pathSeparator}cx.exe',
            )
            ..createSync(recursive: true)
            ..writeAsStringSync('outgoing');

      final command = UpgradeCommand(
        UpgradeInput(installDir: installDir.path),
        config: CliInstallationConfig(
          repository: 'ccisnedev/calculatrix',
          executable: 'cx',
          assets: const {
            'linux': 'cx-linux',
            'macos': 'cx-macos',
            'windows': 'cx-windows.exe',
          },
        ),
        currentVersion: '1.0.0',
        releaseSource: FakeReleaseSource(
          releases: [_release('v9.9.9', asset: _platformAsset)],
        ),
        platformOps: ops,
        downloader: FakeDownloader().call,
        runningExecutable: binary.path,
      );

      final output = await applyCommand(command);

      expect(output.upgraded, isTrue);
    });

    test('uninstall succeeds using the injected fake', () async {
      final ops = FakePlatformOps();
      final command = UninstallCommand(
        UninstallInput(installDir: '/fake/dir'),
        config: CliInstallationConfig(
          repository: 'ccisnedev/calculatrix',
          executable: 'cx',
          assets: _noAssetForThisOS,
        ),
        platformOps: ops,
      );

      await applyCommand(command);

      expect(ops.calls, contains('scheduleDeletion(/fake/dir)'));
    });
  });
}

CliRelease _release(
  String tag, {
  required String asset,
  String url = 'https://dl/asset',
}) => CliRelease(
  tagName: tag,
  assets: [CliReleaseAsset(name: asset, downloadUrl: url)],
);
