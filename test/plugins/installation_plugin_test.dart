/// `InstallationPlugin` — `upgrade` / `uninstall`, and the doctor checks it
/// contributes. Every network, filesystem and platform access goes through a
/// fake from `installation_doubles.dart`: nothing here downloads, writes or
/// deletes anything real.
library;

import 'package:modular_cli_sdk/modular_cli_sdk.dart';
import 'package:test/test.dart';

import '../doubles.dart';
import 'installation_doubles.dart';

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
      // The application's own releases (`v*`) live in the same repository as
      // the CLI's (`cli-v*`) — a tag-prefix filter, not "the newest tag",
      // is what tells them apart.
      final releases = [
        const CliRelease(tagName: 'v9.9.9', assets: []),
        const CliRelease(tagName: 'cli-v1.0.0', assets: []),
      ];
      expect(latestTaggedRelease(releases, 'cli-v')?.tagName, 'cli-v1.0.0');
    });

    test('skips a tag that does not parse as semver once the prefix is stripped', () {
      final releases = [
        const CliRelease(tagName: 'cli-vnightly', assets: []),
        const CliRelease(tagName: 'cli-v1.0.0', assets: []),
      ];
      expect(latestTaggedRelease(releases, 'cli-v')?.tagName, 'cli-v1.0.0');
    });

    test('returns null when nothing matches the prefix', () {
      final releases = [const CliRelease(tagName: 'v9.9.9', assets: [])];
      expect(latestTaggedRelease(releases, 'cli-v'), isNull);
    });
  });

  group('upgrade', () {
    test('invoked with neither --plan nor --apply is refused', () async {
      final cli = _cliWith(_upgradePlugin());

      final err = MemorySink();
      final code = await cli.run(['upgrade'], stderr: err);

      expect(code, ExitCode.validationFailed);
    });

    test('--plan shows the release it would install and changes nothing', () async {
      final fileSystem = FakeFileSystem(onPath: {'cx': '/usr/local/bin/cx'});
      final cli = _cliWith(
        _upgradePlugin(
          releases: [_release('cli-v1.1.0', asset: 'cx-linux')],
          fileSystem: fileSystem,
        ),
      );

      final out = MemorySink();
      final code = await cli.run(['upgrade', '--plan'], stdout: out);

      expect(code, ExitCode.ok);
      expect(out.output, contains('cx-linux'));
      expect(fileSystem.written, isEmpty);
    });

    test('already on the latest version reports nothing to do', () async {
      final cli = _cliWith(
        _upgradePlugin(releases: [_release('cli-v1.0.0', asset: 'cx-linux')]),
      );

      final out = MemorySink();
      final code = await cli.run(['upgrade', '--apply', '--autoapprove'], stdout: out);

      expect(code, ExitCode.ok);
    });

    test('a failed release lookup exits 1 with a structured id', () async {
      final cli = _cliWith(
        _upgradePlugin(releaseError: const CliReleaseLookupFailure('no network')),
      );

      final err = MemorySink();
      final code = await cli.run(['upgrade', '--apply', '--autoapprove'], stderr: err);

      expect(code, ExitCode.genericError);
      expect(err.output, contains('release-lookup-failed'));
    });

    test('a failed release lookup exits 1 under --plan too', () async {
      // Amendment (calculatrix runbook D34 / spec section 6): --plan does not
      // shield a release lookup, because the lookup has to happen before
      // there is anything to plan.
      final cli = _cliWith(
        _upgradePlugin(releaseError: const CliReleaseLookupFailure('no network')),
      );

      final err = MemorySink();
      final code = await cli.run(['upgrade', '--plan'], stderr: err);

      expect(code, ExitCode.genericError);
      expect(err.output, contains('release-lookup-failed'));
    });

    test('--apply downloads and installs the newer release', () async {
      final fileSystem = FakeFileSystem(onPath: {'cx': '/usr/local/bin/cx'});
      final downloader = FakeDownloader(bytes: const [9, 9, 9]);
      final cli = _cliWith(
        _upgradePlugin(
          releases: [_release('cli-v1.1.0', asset: 'cx-linux', url: 'https://dl/cx-linux')],
          fileSystem: fileSystem,
          downloader: downloader,
        ),
      );

      final out = MemorySink();
      final code = await cli.run(['upgrade', '--apply', '--autoapprove'], stdout: out);

      expect(code, ExitCode.ok);
      expect(downloader.requested, ['https://dl/cx-linux']);
      expect(fileSystem.written['/usr/local/bin/cx'], [9, 9, 9]);
      expect(out.output, contains('1.1.0'));
    });

    test('a download failure stops the run before anything is installed', () async {
      final fileSystem = FakeFileSystem(onPath: {'cx': '/usr/local/bin/cx'});
      final cli = _cliWith(
        _upgradePlugin(
          releases: [_release('cli-v1.1.0', asset: 'cx-linux')],
          fileSystem: fileSystem,
          downloader: FakeDownloader(error: Exception('connection reset')),
        ),
      );

      final err = MemorySink();
      final out = MemorySink();
      final code = await cli.run(['upgrade', '--apply', '--autoapprove'], stdout: out, stderr: err);

      expect(code, ExitCode.genericError);
      expect(out.output, contains('download-failed'));
      expect(fileSystem.written, isEmpty, reason: 'no rollback needed: nothing ran after the failure');
    });

    test('a file-access failure reports the download step as already done', () async {
      final fileSystem = FakeFileSystem(onPath: {'cx': '/usr/local/bin/cx'})
        ..writeError = Exception('permission denied');
      final cli = _cliWith(
        _upgradePlugin(
          releases: [_release('cli-v1.1.0', asset: 'cx-linux')],
          fileSystem: fileSystem,
        ),
      );

      final out = MemorySink();
      final code = await cli.run(['upgrade', '--apply', '--autoapprove'], stdout: out);

      expect(code, ExitCode.genericError);
      expect(out.output, contains('file-access-denied'));
      // Stops at the failed step and reports the step already done — the
      // download — without retrying or rolling it back.
      expect(out.output, contains('stepsCompleted: [cx-linux]'));
    });

    test('the executable not being on PATH is a file-access-denied build failure', () async {
      final cli = _cliWith(
        _upgradePlugin(
          releases: [_release('cli-v1.1.0', asset: 'cx-linux')],
          fileSystem: FakeFileSystem(),
        ),
      );

      final err = MemorySink();
      final code = await cli.run(['upgrade', '--apply', '--autoapprove'], stderr: err);

      expect(code, ExitCode.genericError);
      expect(err.output, contains('file-access-denied'));
    });
  });

  group('uninstall', () {
    test('invoked with neither --plan nor --apply is refused', () async {
      final cli = _cliWith(_upgradePlugin());

      final code = await cli.run(['uninstall'], stderr: MemorySink());
      expect(code, ExitCode.validationFailed);
    });

    test('nothing on PATH: nothing to do', () async {
      final cli = _cliWith(_upgradePlugin(fileSystem: FakeFileSystem()));

      final code = await cli.run(['uninstall', '--apply', '--autoapprove'], stdout: MemorySink());
      expect(code, ExitCode.ok);
    });

    test('removes the executable, and the alias when it points at the same binary', () async {
      final fileSystem = FakeFileSystem(
        onPath: {'cx': '/usr/local/bin/cx', 'calculatrix': '/usr/local/bin/cx'},
      );
      final cli = _cliWith(_upgradePlugin(fileSystem: fileSystem));

      final code = await cli.run(['uninstall', '--apply', '--autoapprove'], stdout: MemorySink());

      expect(code, ExitCode.ok);
      expect(fileSystem.deleted, ['/usr/local/bin/cx', '/usr/local/bin/cx']);
    });

    test('leaves an alias that resolves elsewhere untouched', () async {
      final fileSystem = FakeFileSystem(
        onPath: {'cx': '/usr/local/bin/cx', 'calculatrix': '/opt/other/calculatrix'},
      );
      final cli = _cliWith(_upgradePlugin(fileSystem: fileSystem));

      await cli.run(['uninstall', '--apply', '--autoapprove'], stdout: MemorySink());

      expect(fileSystem.deleted, ['/usr/local/bin/cx']);
    });

    test('a failure to remove the executable reports file-access-denied', () async {
      final fileSystem = FakeFileSystem(onPath: {'cx': '/usr/local/bin/cx'})
        ..deleteError = Exception('busy');
      final cli = _cliWith(_upgradePlugin(fileSystem: fileSystem));

      final out = MemorySink();
      final code = await cli.run(['uninstall', '--apply', '--autoapprove'], stdout: out);

      expect(code, ExitCode.genericError);
      expect(out.output, contains('file-access-denied'));
    });
  });

  group('doctor checks contributed by InstallationPlugin', () {
    test('binary found, alias correct, up to date: everything ok', () async {
      final fileSystem = FakeFileSystem(
        onPath: {'cx': '/usr/local/bin/cx', 'calculatrix': '/usr/local/bin/cx'},
      );
      final cli = _cliWithDoctor(
        _upgradePlugin(
          fileSystem: fileSystem,
          releases: [_release('cli-v1.0.0', asset: 'cx-linux')],
        ),
      );

      final code = await cli.run(['doctor'], stdout: MemorySink());
      expect(code, ExitCode.ok);
    });

    test('binary missing from PATH is a doctor error', () async {
      final cli = _cliWithDoctor(_upgradePlugin(fileSystem: FakeFileSystem()));

      final code = await cli.run(['doctor'], stdout: MemorySink());
      expect(code, ExitCode.configError);
    });

    test('alias resolving to a different binary is a doctor error', () async {
      final fileSystem = FakeFileSystem(
        onPath: {'cx': '/usr/local/bin/cx', 'calculatrix': '/opt/other/calculatrix'},
      );
      final cli = _cliWithDoctor(_upgradePlugin(fileSystem: fileSystem));

      final code = await cli.run(['doctor'], stdout: MemorySink());
      expect(code, ExitCode.configError);
    });

    test('a newer release is a warning, not an error', () async {
      final fileSystem = FakeFileSystem(
        onPath: {'cx': '/usr/local/bin/cx', 'calculatrix': '/usr/local/bin/cx'},
      );
      final cli = _cliWithDoctor(
        _upgradePlugin(
          fileSystem: fileSystem,
          releases: [_release('cli-v9.9.9', asset: 'cx-linux')],
        ),
      );

      final out = MemorySink();
      final code = await cli.run(['doctor'], stdout: out);

      expect(code, ExitCode.ok);
      expect(out.output, contains('warning'));
    });

    test('a failed release lookup is a warning, not an error', () async {
      final fileSystem = FakeFileSystem(
        onPath: {'cx': '/usr/local/bin/cx', 'calculatrix': '/usr/local/bin/cx'},
      );
      final cli = _cliWithDoctor(
        _upgradePlugin(
          fileSystem: fileSystem,
          releaseError: const CliReleaseLookupFailure('no network'),
        ),
      );

      final out = MemorySink();
      final code = await cli.run(['doctor'], stdout: out);

      expect(code, ExitCode.ok);
      expect(out.output, contains('warning'));
    });
  });
}

InstallationPlugin _upgradePlugin({
  List<CliRelease> releases = const [],
  Object? releaseError,
  FakeFileSystem? fileSystem,
  FakeDownloader? downloader,
  String tagPrefix = 'cli-v',
}) => InstallationPlugin(
  config: CliInstallationConfig(
    repository: 'ccisnedev/calculatrix',
    tagPrefix: tagPrefix,
    executable: 'cx',
    alias: 'calculatrix',
    assets: const {'linux': 'cx-linux', 'macos': 'cx-macos', 'windows': 'cx-windows.exe'},
  ),
  releaseSource: FakeReleaseSource(releases: releases, error: releaseError),
  downloader: downloader ?? FakeDownloader(),
  fileSystem: fileSystem ?? FakeFileSystem(onPath: const {'cx': '/usr/local/bin/cx'}),
  platform: const FakePlatform('linux'),
);

CliRelease _release(String tag, {required String asset, String url = 'https://dl/asset'}) =>
    CliRelease(tagName: tag, assets: [CliReleaseAsset(name: asset, downloadUrl: url)]);

ModularCli _cliWith(InstallationPlugin plugin) =>
    ModularCli(name: 'cx', version: '1.0.0')
      ..plugin(const DoctorPlugin())
      ..plugin(plugin);

ModularCli _cliWithDoctor(InstallationPlugin plugin) => _cliWith(plugin);
