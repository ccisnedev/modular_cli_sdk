@TestOn('linux')
library;

/// A Linux end-to-end pass for the installation plugin (issue #40): the real
/// `LinuxPlatformOps` against real files, driving the actual
/// `UpgradeCommand`/`UninstallCommand` production classes (the exact ones
/// `InstallationPlugin.setup` registers), with only the release lookup and
/// the download faked. No network is reached anywhere in this file.
///
/// Why not a full `ModularCli.run(['upgrade', '--apply'])`: `installDir` is
/// never an argv-level option. `InstallationPlugin.setup` always builds
/// `UpgradeInput()`/`UninstallInput()` with none, which fall back to
/// `Platform.resolvedExecutable`, the running `dart test` binary itself (see
/// `UpgradeInput`'s constructor in installation_plugin.dart). Driving the
/// commands directly with an explicit `installDir`, as this file and
/// `installation_lazy_platform_test.dart` both do, is the actual seam the
/// production code offers; a real CLI run against a temp installDir is not
/// possible without adding one, which would be a design decision, not a
/// mechanical test.
///
/// HOME and XDG_*: grepping lib/ for either turns up nothing.
/// `LinuxPlatformOps.getEnvVariable` reads whatever `Platform.environment`
/// already holds; `setEnvVariable` is a documented no-op ("the install
/// script handles PATH setup during installation"). Nothing here reads or
/// writes HOME or XDG_* on Linux, and `installDir` is always explicit, so
/// there is nothing for those variables to isolate. This suite gets the same
/// isolation the issue is after by using its own temp `installDir`
/// throughout instead of pointing real environment variables anywhere.
///
/// The `~/.local/bin` symlink case: per docs/installation-parity.md this is
/// each CLI's own install script's job, never the SDK's. On Linux
/// `setEnvVariable` is a no-op, so `UnsetFromPath` never actually touches
/// PATH here at all; there is no SDK code path a symlinked bin directory
/// could reach, so nothing to exercise.
import 'dart:io';

import 'package:modular_cli_sdk/modular_cli_sdk.dart';
import 'package:modular_cli_sdk/testing.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'installation_doubles.dart';

void main() {
  late Directory tempRoot;

  setUp(() {
    tempRoot = Directory.systemTemp.createTempSync('mcs_linux_e2e_');
  });

  tearDown(() {
    if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
  });

  CliInstallationConfig config({String? tagPrefix}) => CliInstallationConfig(
    repository: 'ccisnedev/calculatrix',
    executable: 'cx',
    assets: const {'linux': 'cx-linux.tar.gz'},
    tagPrefix: tagPrefix,
  );

  // Builds a real gzipped tar containing bin/cx, a shell script made
  // executable with a real chmod, using the real `tar` binary: the same
  // extraction path LinuxPlatformOps.expandArchive itself uses, so checking
  // the exec bit afterward is meaningful rather than assumed.
  Future<File> buildFixtureArchive(Directory dir, String version) async {
    final source = Directory(p.join(dir.path, 'fixture_src'))
      ..createSync(recursive: true);
    final bin = File(p.join(source.path, 'bin', 'cx'))
      ..createSync(recursive: true);
    bin.writeAsStringSync('#!/bin/sh\necho "cx version $version"\n');
    final chmod = await Process.run('chmod', ['+x', bin.path]);
    if (chmod.exitCode != 0) {
      fail('Could not chmod the fixture binary: ${chmod.stderr}');
    }

    final archive = File(p.join(dir.path, 'cx-linux.tar.gz'));
    final result = await Process.run('tar', [
      'czf',
      archive.path,
      '-C',
      source.path,
      'bin',
    ]);
    if (result.exitCode != 0) {
      fail('Could not build the fixture archive: ${result.stderr}');
    }
    return archive;
  }

  test(
    'upgrade --plan looks up the release but never touches installDir',
    () async {
      final installDir = Directory(p.join(tempRoot.path, 'install'))
        ..createSync(recursive: true);

      final command = UpgradeCommand(
        UpgradeInput(installDir: installDir.path),
        config: config(),
        currentVersion: '1.0.0',
        releaseSource: FakeReleaseSource(
          releases: [
            CliRelease(
              tagName: 'v2.0.0',
              assets: [
                CliReleaseAsset(
                  name: 'cx-linux.tar.gz',
                  downloadUrl: 'https://example.invalid/cx-linux.tar.gz',
                ),
              ],
            ),
          ],
        ),
        platformOps: LinuxPlatformOps(
          binaryName: 'cx',
          assetName: 'cx-linux.tar.gz',
        ),
        runningExecutable: p.join(installDir.path, 'bin', 'cx_running_stub'),
      );

      final previews = await previewCommand(command);

      expect(previews, isNotEmpty);
      expect(previews.first.detail, contains('cx-linux.tar.gz'));
      // A plan is a description, not an action: nothing was extracted.
      expect(Directory(p.join(installDir.path, 'bin')).existsSync(), isFalse);
    },
  );

  test('upgrade --apply downloads through the injected downloader (no '
      'network), extracts with the real tar-based LinuxPlatformOps, and '
      'leaves the installed binary executable', () async {
    final installDir = Directory(p.join(tempRoot.path, 'install'))
      ..createSync(recursive: true);
    final archive = await buildFixtureArchive(tempRoot, '2.0.0');

    final requested = <String>[];
    Future<void> copyFixture(String url, String destination) async {
      requested.add(url);
      await archive.copy(destination);
    }

    final command = UpgradeCommand(
      UpgradeInput(installDir: installDir.path),
      config: config(),
      currentVersion: '1.0.0',
      releaseSource: FakeReleaseSource(
        releases: [
          CliRelease(
            tagName: 'v2.0.0',
            assets: [
              CliReleaseAsset(
                name: 'cx-linux.tar.gz',
                downloadUrl: 'https://example.invalid/cx-linux.tar.gz',
              ),
            ],
          ),
        ],
      ),
      platformOps: LinuxPlatformOps(
        binaryName: 'cx',
        assetName: 'cx-linux.tar.gz',
      ),
      downloader: copyFixture,
      runningExecutable: p.join(installDir.path, 'bin', 'cx_running_stub'),
    );

    final output = await applyCommand(command);

    expect(output.upgraded, isTrue);
    expect(output.newVersion, '2.0.0');
    expect(requested, ['https://example.invalid/cx-linux.tar.gz']);

    final installedBinary = File(p.join(installDir.path, 'bin', 'cx'));
    expect(installedBinary.existsSync(), isTrue);
    // Owner execute bit (0o100 = 0x40): preserved by tar itself, not set by
    // any code in LinuxPlatformOps, which never chmods anything. This pins
    // that the real extraction path in fact produces a binary that can be
    // run, which is what "verifyAfterInstall" (default true, exercised
    // implicitly: this command would already have failed above if the
    // freshly extracted binary could not be launched) actually depends on.
    final mode = installedBinary.statSync().mode;
    expect(mode & 0x40, isNot(0), reason: 'installed binary is not executable');
  });

  test('uninstall deletes the install directory synchronously: gone by the '
      'time the command finishes, not eventually (issue #40, defect 1, at '
      'the full command level)', () async {
    final installDir = Directory(p.join(tempRoot.path, 'install'))
      ..createSync(recursive: true);
    for (var i = 0; i < 4000; i++) {
      File(p.join(installDir.path, 'file_$i.txt')).writeAsStringSync('x');
    }

    final command = UninstallCommand(
      UninstallInput(installDir: installDir.path),
      config: config(),
      platformOps: LinuxPlatformOps(
        binaryName: 'cx',
        assetName: 'cx-linux.tar.gz',
      ),
    );

    await applyCommand(command);

    // No polling: the exact "immediate directory check" the issue asks
    // for, now at the full uninstall-command level rather than just
    // scheduleDeletion in isolation.
    expect(installDir.existsSync(), isFalse);
  });

  test("the cli-v tag prefix picks this CLI's own release, skipping an "
      'application tag that shares the same repository', () async {
    final installDir = Directory(p.join(tempRoot.path, 'install'))
      ..createSync(recursive: true);
    final archive = await buildFixtureArchive(tempRoot, '1.5.0');

    final requested = <String>[];
    Future<void> copyFixture(String url, String destination) async {
      requested.add(url);
      await archive.copy(destination);
    }

    final command = UpgradeCommand(
      UpgradeInput(installDir: installDir.path),
      config: config(tagPrefix: 'cli-v'),
      currentVersion: '1.0.0',
      releaseSource: FakeReleaseSource(
        releases: [
          // The application's own tag in the same repository: no prefix
          // match, not a candidate, and its (much higher) version must
          // not win.
          CliRelease(
            tagName: 'v9.0.0',
            assets: [
              CliReleaseAsset(
                name: 'cx-linux.tar.gz',
                downloadUrl: 'https://example.invalid/app.tar.gz',
              ),
            ],
          ),
          CliRelease(
            tagName: 'cli-v1.5.0',
            assets: [
              CliReleaseAsset(
                name: 'cx-linux.tar.gz',
                downloadUrl: 'https://example.invalid/cli.tar.gz',
              ),
            ],
          ),
        ],
      ),
      platformOps: LinuxPlatformOps(
        binaryName: 'cx',
        assetName: 'cx-linux.tar.gz',
      ),
      downloader: copyFixture,
      runningExecutable: p.join(installDir.path, 'bin', 'cx_running_stub'),
    );

    final output = await applyCommand(command);

    expect(output.upgraded, isTrue);
    expect(output.newVersion, '1.5.0');
    expect(requested, ['https://example.invalid/cli.tar.gz']);
  });
}
