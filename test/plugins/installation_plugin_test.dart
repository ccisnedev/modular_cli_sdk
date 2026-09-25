/// `InstallationPlugin`: `upgrade` / `uninstall`, and the doctor checks it
/// contributes. Every network, filesystem and platform access goes through a
/// fake from `installation_doubles.dart`: nothing here downloads, writes or
/// deletes anything real.
library;

import 'dart:io' as io;

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
      // the CLI's (`cli-v*`): a tag-prefix filter, not "the newest tag",
      // is what tells them apart.
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

  group('upgrade', () {
    test('invoked with neither --plan nor --apply is refused', () async {
      final cli = _cliWith(_upgradePlugin());

      final err = MemorySink();
      final code = await cli.run(['upgrade'], stderr: err);

      expect(code, ExitCode.validationFailed);
    });

    test(
      '--plan shows the release it would install and changes nothing',
      () async {
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
      },
    );

    test('already on the latest version reports nothing to do', () async {
      final cli = _cliWith(
        _upgradePlugin(releases: [_release('cli-v1.0.0', asset: 'cx-linux')]),
      );

      final out = MemorySink();
      final code = await cli.run([
        'upgrade',
        '--apply',
        '--autoapprove',
      ], stdout: out);

      expect(code, ExitCode.ok);
    });

    test('a failed release lookup exits 1 with a structured id', () async {
      final cli = _cliWith(
        _upgradePlugin(
          releaseError: const CliReleaseLookupFailure('no network'),
        ),
      );

      final err = MemorySink();
      final code = await cli.run([
        'upgrade',
        '--apply',
        '--autoapprove',
      ], stderr: err);

      expect(code, ExitCode.genericError);
      expect(err.output, contains('release-lookup-failed'));
    });

    test('a failed release lookup exits 1 under --plan too', () async {
      // Amendment (calculatrix runbook D34 / spec section 6): --plan does not
      // shield a release lookup, because the lookup has to happen before
      // there is anything to plan.
      final cli = _cliWith(
        _upgradePlugin(
          releaseError: const CliReleaseLookupFailure('no network'),
        ),
      );

      final err = MemorySink();
      final code = await cli.run(['upgrade', '--plan'], stderr: err);

      expect(code, ExitCode.genericError);
      expect(err.output, contains('release-lookup-failed'));
    });

    test(
      'a release tag that does not parse as semver exits 1 with a structured id',
      () async {
        final cli = _cliWith(
          _upgradePlugin(
            releases: [_release('cli-vnightly', asset: 'cx-linux')],
          ),
        );

        final err = MemorySink();
        final code = await cli.run([
          'upgrade',
          '--apply',
          '--autoapprove',
        ], stderr: err);

        expect(code, ExitCode.genericError);
        expect(err.output, contains('release-lookup-failed'));
        expect(err.output, contains('cli-vnightly'));
      },
    );

    test(
      '--apply with no --autoapprove still applies: the explicit --apply is the authorization',
      () async {
        // Issue #28: `upgrade --apply` never shows the interactive approval
        // prompt and never refuses for lack of a terminal, because naming
        // --apply on this route already is the authorization. --autoapprove
        // is deliberately absent here so this cannot pass by accident on a
        // route that still gated on it.
        final fileSystem = FakeFileSystem(onPath: {'cx': '/usr/local/bin/cx'});
        final downloader = FakeDownloader(bytes: const [9, 9, 9]);
        final cli = _cliWith(
          _upgradePlugin(
            releases: [
              _release(
                'cli-v1.1.0',
                asset: 'cx-linux',
                url: 'https://dl/cx-linux',
              ),
            ],
            fileSystem: fileSystem,
            downloader: downloader,
          ),
        );

        final out = MemorySink();
        final code = await cli.run(['upgrade', '--apply'], stdout: out);

        expect(code, ExitCode.ok);
        expect(downloader.requested, ['https://dl/cx-linux']);
        expect(fileSystem.written['/usr/local/bin/cx'], [9, 9, 9]);
      },
    );

    test('--apply downloads and installs the newer release', () async {
      final fileSystem = FakeFileSystem(onPath: {'cx': '/usr/local/bin/cx'});
      final downloader = FakeDownloader(bytes: const [9, 9, 9]);
      final cli = _cliWith(
        _upgradePlugin(
          releases: [
            _release(
              'cli-v1.1.0',
              asset: 'cx-linux',
              url: 'https://dl/cx-linux',
            ),
          ],
          fileSystem: fileSystem,
          downloader: downloader,
        ),
      );

      final out = MemorySink();
      final code = await cli.run([
        'upgrade',
        '--apply',
        '--autoapprove',
      ], stdout: out);

      expect(code, ExitCode.ok);
      expect(downloader.requested, ['https://dl/cx-linux']);
      expect(fileSystem.written['/usr/local/bin/cx'], [9, 9, 9]);
      expect(out.output, contains('1.1.0'));
    });

    test(
      'a download failure stops the run before anything is installed',
      () async {
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
        final code = await cli.run(
          ['upgrade', '--apply', '--autoapprove'],
          stdout: out,
          stderr: err,
        );

        expect(code, ExitCode.genericError);
        expect(out.output, contains('download-failed'));
        expect(
          fileSystem.written,
          isEmpty,
          reason: 'no rollback needed: nothing ran after the failure',
        );
      },
    );

    test(
      'a file-access failure reports the download step as already done',
      () async {
        final fileSystem = FakeFileSystem(onPath: {'cx': '/usr/local/bin/cx'})
          ..writeError = Exception('permission denied');
        final cli = _cliWith(
          _upgradePlugin(
            releases: [_release('cli-v1.1.0', asset: 'cx-linux')],
            fileSystem: fileSystem,
          ),
        );

        final out = MemorySink();
        final code = await cli.run([
          'upgrade',
          '--apply',
          '--autoapprove',
        ], stdout: out);

        expect(code, ExitCode.genericError);
        expect(out.output, contains('file-access-denied'));
        // Stops at the failed step and reports the step already done (the
        // download) without retrying or rolling it back.
        expect(out.output, contains('stepsCompleted: [cx-linux]'));
      },
    );

    test(
      'the executable not being on PATH is a file-access-denied build failure',
      () async {
        final cli = _cliWith(
          _upgradePlugin(
            releases: [_release('cli-v1.1.0', asset: 'cx-linux')],
            fileSystem: FakeFileSystem(),
          ),
        );

        final err = MemorySink();
        final code = await cli.run([
          'upgrade',
          '--apply',
          '--autoapprove',
        ], stderr: err);

        expect(code, ExitCode.genericError);
        expect(err.output, contains('file-access-denied'));
      },
    );

    test('installs to the resolved target, not a symlinked PATH entry, when '
        'the executable on PATH is a symlink', () async {
      // `cx` on PATH is a symlink to a versioned install directory (as a
      // package manager, or a previous upgrade, might leave it): writing
      // to the raw PATH entry would replace the link itself with a plain
      // file rather than upgrading what it points at, and sever the link.
      final fileSystem = FakeFileSystem(
        onPath: {'cx': '/usr/local/bin/cx'},
        canonicalTargets: {'/usr/local/bin/cx': '/opt/calculatrix/cx-1.0.0'},
      );
      final downloader = FakeDownloader(bytes: const [9, 9, 9]);
      final cli = _cliWith(
        _upgradePlugin(
          releases: [_release('cli-v1.1.0', asset: 'cx-linux')],
          fileSystem: fileSystem,
          downloader: downloader,
        ),
      );

      final code = await cli.run([
        'upgrade',
        '--apply',
        '--autoapprove',
      ], stdout: MemorySink());

      expect(code, ExitCode.ok);
      expect(fileSystem.written, {
        '/opt/calculatrix/cx-1.0.0': [9, 9, 9],
      });
    });

    test(
      '--plan reports the resolved target, not the symlinked PATH entry',
      () async {
        final fileSystem = FakeFileSystem(
          onPath: {'cx': '/usr/local/bin/cx'},
          canonicalTargets: {'/usr/local/bin/cx': '/opt/calculatrix/cx-1.0.0'},
        );
        final cli = _cliWith(
          _upgradePlugin(
            releases: [_release('cli-v1.1.0', asset: 'cx-linux')],
            fileSystem: fileSystem,
          ),
        );

        final out = MemorySink();
        final code = await cli.run(['upgrade', '--plan'], stdout: out);

        expect(code, ExitCode.ok);
        expect(out.output, contains('/opt/calculatrix/cx-1.0.0'));
      },
    );

    test('a resolution failure reports file-access-denied rather than '
        'installing over the symlink', () async {
      final fileSystem = FakeFileSystem(onPath: {'cx': '/usr/local/bin/cx'})
        ..canonicalizeError = Exception('too many levels of symbolic links');
      final cli = _cliWith(
        _upgradePlugin(
          releases: [_release('cli-v1.1.0', asset: 'cx-linux')],
          fileSystem: fileSystem,
        ),
      );

      final err = MemorySink();
      final code = await cli.run([
        'upgrade',
        '--apply',
        '--autoapprove',
      ], stderr: err);

      expect(code, ExitCode.genericError);
      expect(err.output, contains('file-access-denied'));
    });

    test(
      'a real symlinked install target: both the alias and the resolved '
      'binary reach the new content after --apply',
      () async {
        final tempDir = io.Directory.systemTemp.createTempSync(
          'upgrade_symlink_test_',
        );
        addTearDown(() {
          if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
        });

        final targetPath = '${tempDir.path}${io.Platform.pathSeparator}cx-real';
        final linkPath = '${tempDir.path}${io.Platform.pathSeparator}cx';
        io.File(targetPath).writeAsBytesSync([1, 2, 3]);
        io.Process.runSync('chmod', ['+x', targetPath]);
        try {
          io.Link(linkPath).createSync(targetPath);
        } on io.FileSystemException {
          return;
        }

        final fileSystem = IoCliFileSystem(pathDirectories: [tempDir.path]);
        final downloader = FakeDownloader(bytes: const [9, 9, 9]);
        final cli = _cliWith(
          _upgradePlugin(
            releases: [_release('cli-v1.1.0', asset: 'cx-linux')],
            fileSystem: fileSystem,
            downloader: downloader,
          ),
        );

        final code = await cli.run([
          'upgrade',
          '--apply',
          '--autoapprove',
        ], stdout: MemorySink());

        expect(code, ExitCode.ok);
        // The link itself is untouched; the file it points at was replaced,
        // so both names now read the new content.
        expect(io.File(targetPath).readAsBytesSync(), [9, 9, 9]);
        expect(io.File(linkPath).readAsBytesSync(), [9, 9, 9]);
        expect(io.Link(linkPath).targetSync(), targetPath);
      },
      skip: io.Platform.isWindows
          ? 'symlink creation needs a privilege this environment may lack'
          : false,
    );
  });

  group('uninstall', () {
    test('invoked with neither --plan nor --apply is refused', () async {
      final cli = _cliWith(_upgradePlugin());

      final code = await cli.run(['uninstall'], stderr: MemorySink());
      expect(code, ExitCode.validationFailed);
    });

    test('nothing on PATH: nothing to do', () async {
      final cli = _cliWith(_upgradePlugin(fileSystem: FakeFileSystem()));

      final code = await cli.run([
        'uninstall',
        '--apply',
        '--autoapprove',
      ], stdout: MemorySink());
      expect(code, ExitCode.ok);
    });

    test(
      'removes the executable; the alias resolving to the same raw path is not deleted twice',
      () async {
        final fileSystem = FakeFileSystem(
          onPath: {
            'cx': '/usr/local/bin/cx',
            'calculatrix': '/usr/local/bin/cx',
          },
        );
        final cli = _cliWith(_upgradePlugin(fileSystem: fileSystem));

        final code = await cli.run([
          'uninstall',
          '--apply',
          '--autoapprove',
        ], stdout: MemorySink());

        expect(code, ExitCode.ok);
        // Both names resolve to the exact same path: it is queued for removal
        // once, not once per name. The fake rejects a second delete of the
        // same path, so a regression here would fail this test rather than
        // just producing a redundant, harmless-looking duplicate entry.
        expect(fileSystem.deleted, ['/usr/local/bin/cx']);
      },
    );

    test(
      'removes the executable and a symlinked alias that resolves to it under a different path',
      () async {
        // `cx` and `calculatrix` are different PATH entries (a valid symlink),
        // so their raw paths differ, but they canonicalize to the same file:
        // both are real entries and both must be removed, exactly once each.
        final fileSystem = FakeFileSystem(
          onPath: {
            'cx': '/usr/local/bin/cx',
            'calculatrix': '/usr/local/bin/calculatrix',
          },
          canonicalTargets: {
            '/usr/local/bin/cx': '/usr/local/bin/cx',
            '/usr/local/bin/calculatrix': '/usr/local/bin/cx',
          },
        );
        final cli = _cliWith(_upgradePlugin(fileSystem: fileSystem));

        final code = await cli.run([
          'uninstall',
          '--apply',
          '--autoapprove',
        ], stdout: MemorySink());

        // The alias is removed before the executable: deleting the
        // executable first would leave the symlinked alias dangling, and a
        // real filesystem's delete of a dangling symlink fails on Linux.
        expect(code, ExitCode.ok);
        expect(fileSystem.deleted, [
          '/usr/local/bin/calculatrix',
          '/usr/local/bin/cx',
        ]);
      },
    );

    test(
      '--apply with no --autoapprove still applies: the explicit --apply is the authorization',
      () async {
        final fileSystem = FakeFileSystem(onPath: {'cx': '/usr/local/bin/cx'});
        final cli = _cliWith(_upgradePlugin(fileSystem: fileSystem));

        final code = await cli.run([
          'uninstall',
          '--apply',
        ], stdout: MemorySink());

        expect(code, ExitCode.ok);
        expect(fileSystem.deleted, ['/usr/local/bin/cx']);
      },
    );

    test('--plan shows the removal and changes nothing', () async {
      final fileSystem = FakeFileSystem(
        onPath: {'cx': '/usr/local/bin/cx', 'calculatrix': '/usr/local/bin/cx'},
      );
      final cli = _cliWith(_upgradePlugin(fileSystem: fileSystem));

      final out = MemorySink();
      final code = await cli.run(['uninstall', '--plan'], stdout: out);

      expect(code, ExitCode.ok);
      expect(out.output, contains('/usr/local/bin/cx'));
      expect(fileSystem.deleted, isEmpty);
    });

    test('leaves an alias that resolves elsewhere untouched', () async {
      final fileSystem = FakeFileSystem(
        onPath: {
          'cx': '/usr/local/bin/cx',
          'calculatrix': '/opt/other/calculatrix',
        },
      );
      final cli = _cliWith(_upgradePlugin(fileSystem: fileSystem));

      await cli.run([
        'uninstall',
        '--apply',
        '--autoapprove',
      ], stdout: MemorySink());

      expect(fileSystem.deleted, ['/usr/local/bin/cx']);
    });

    test(
      'a failure to remove the executable reports file-access-denied',
      () async {
        final fileSystem = FakeFileSystem(onPath: {'cx': '/usr/local/bin/cx'})
          ..deleteError = Exception('busy');
        final cli = _cliWith(_upgradePlugin(fileSystem: fileSystem));

        final out = MemorySink();
        final code = await cli.run([
          'uninstall',
          '--apply',
          '--autoapprove',
        ], stdout: out);

        expect(code, ExitCode.genericError);
        expect(out.output, contains('file-access-denied'));
      },
    );

    test('on Windows, the running executable is moved aside and a detached '
        'process is started to remove it once this process exits', () async {
      final fileSystem = FakeFileSystem(onPath: {'cx': '/usr/local/bin/cx'});
      final processLauncher = FakeProcessLauncher(pid: 4242);
      final cli = _cliWith(
        _upgradePlugin(
          fileSystem: fileSystem,
          platform: const FakePlatform('windows'),
          processLauncher: processLauncher,
        ),
      );

      final out = MemorySink();
      final code = await cli.run([
        'uninstall',
        '--apply',
        '--autoapprove',
      ], stdout: out);

      expect(code, ExitCode.ok);
      // It is renamed aside, never deleted directly: Windows will not let
      // a running executable delete itself.
      expect(fileSystem.deleted, isEmpty);
      expect(fileSystem.renamed, [
        ('/usr/local/bin/cx', '/usr/local/bin/cx.uninstall-4242.old'),
      ]);
      expect(processLauncher.started, hasLength(1));
      final (executable, arguments) = processLauncher.started.single;
      expect(executable, 'cmd');
      expect(arguments.first, '/c');
      expect(arguments.join(' '), contains('4242'));
      expect(
        arguments.join(' '),
        contains('/usr/local/bin/cx.uninstall-4242.old'),
      );
      // No silent success: the plan says explicitly that removal is
      // deferred, rather than implying the file is already gone.
      expect(
        out.output,
        contains('/usr/local/bin/cx will be removed when this process exits'),
      );
    });

    test('on Windows, if the detached process cannot be started, uninstall '
        'fails with file-access-denied instead of a silent success', () async {
      final fileSystem = FakeFileSystem(onPath: {'cx': '/usr/local/bin/cx'});
      final processLauncher = FakeProcessLauncher(
        startError: Exception('no shell available'),
      );
      final cli = _cliWith(
        _upgradePlugin(
          fileSystem: fileSystem,
          platform: const FakePlatform('windows'),
          processLauncher: processLauncher,
        ),
      );

      final out = MemorySink();
      final code = await cli.run([
        'uninstall',
        '--apply',
        '--autoapprove',
      ], stdout: out);

      expect(code, ExitCode.genericError);
      expect(out.output, contains('file-access-denied'));
      // The rename already happened; the failure message says where the
      // file ended up rather than leaving it unaccounted for.
      expect(out.output, contains('/usr/local/bin/cx.uninstall-4242.old'));
    });

    test(
      'a real symlinked alias: removing the alias before the target avoids '
      'the dangling-symlink delete failure',
      () async {
        final tempDir = io.Directory.systemTemp.createTempSync(
          'uninstall_symlink_test_',
        );
        addTearDown(() {
          if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
        });

        final binaryPath = '${tempDir.path}${io.Platform.pathSeparator}cx';
        final aliasPath =
            '${tempDir.path}${io.Platform.pathSeparator}calculatrix';
        io.File(binaryPath).writeAsBytesSync([1]);
        io.Process.runSync('chmod', ['+x', binaryPath]);
        try {
          io.Link(aliasPath).createSync(binaryPath);
        } on io.FileSystemException {
          return;
        }

        final fileSystem = IoCliFileSystem(pathDirectories: [tempDir.path]);
        final cli = _cliWith(_upgradePlugin(fileSystem: fileSystem));

        final code = await cli.run([
          'uninstall',
          '--apply',
          '--autoapprove',
        ], stdout: MemorySink());

        expect(code, ExitCode.ok);
        expect(io.File(binaryPath).existsSync(), isFalse);
        expect(io.Link(aliasPath).existsSync(), isFalse);
      },
      skip: io.Platform.isWindows
          ? 'symlink creation needs a privilege this environment may lack'
          : false,
    );
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

    test(
      'a symlinked alias that canonicalizes to the same binary is ok, not an error',
      () async {
        // `calculatrix` is a valid symlink to `cx`: their raw PATH entries
        // differ, but they name the same file on disk. Comparing paths by
        // canonical identity, not by string, is what tells this apart from a
        // genuinely broken alias.
        final fileSystem = FakeFileSystem(
          onPath: {
            'cx': '/usr/local/bin/cx',
            'calculatrix': '/usr/local/bin/calculatrix',
          },
          canonicalTargets: {
            '/usr/local/bin/cx': '/usr/local/bin/cx',
            '/usr/local/bin/calculatrix': '/usr/local/bin/cx',
          },
        );
        final cli = _cliWithDoctor(
          _upgradePlugin(
            fileSystem: fileSystem,
            releases: [_release('cli-v1.0.0', asset: 'cx-linux')],
          ),
        );

        final code = await cli.run(['doctor'], stdout: MemorySink());
        expect(code, ExitCode.ok);
      },
    );

    test('alias resolving to a different binary is a doctor error', () async {
      final fileSystem = FakeFileSystem(
        onPath: {
          'cx': '/usr/local/bin/cx',
          'calculatrix': '/opt/other/calculatrix',
        },
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
      // Issue #28's own corrective command, in full: a reader is told
      // exactly what to run, not merely that something is newer.
      expect(
        out.output,
        contains(
          'A newer release is available: cli-v9.9.9 (current: 1.0.0). '
          'Run "calculatrix upgrade --apply" to install it.',
        ),
      );
    });

    test(
      'a release tag that does not parse as semver is a doctor warning naming the tag',
      () async {
        final fileSystem = FakeFileSystem(
          onPath: {
            'cx': '/usr/local/bin/cx',
            'calculatrix': '/usr/local/bin/cx',
          },
        );
        final cli = _cliWithDoctor(
          _upgradePlugin(
            fileSystem: fileSystem,
            releases: [_release('cli-vnightly', asset: 'cx-linux')],
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
  CliFileSystem? fileSystem,
  FakeDownloader? downloader,
  CliPlatform? platform,
  CliProcessLauncher? processLauncher,
  String tagPrefix = 'cli-v',
}) => InstallationPlugin(
  config: CliInstallationConfig(
    repository: 'ccisnedev/calculatrix',
    tagPrefix: tagPrefix,
    executable: 'cx',
    alias: 'calculatrix',
    assets: const {
      'linux': 'cx-linux',
      'macos': 'cx-macos',
      'windows': 'cx-windows.exe',
    },
  ),
  releaseSource: FakeReleaseSource(releases: releases, error: releaseError),
  downloader: downloader ?? FakeDownloader(),
  fileSystem:
      fileSystem ?? FakeFileSystem(onPath: const {'cx': '/usr/local/bin/cx'}),
  platform: platform ?? const FakePlatform('linux'),
  processLauncher: processLauncher,
);

CliRelease _release(
  String tag, {
  required String asset,
  String url = 'https://dl/asset',
}) => CliRelease(
  tagName: tag,
  assets: [CliReleaseAsset(name: asset, downloadUrl: url)],
);

ModularCli _cliWith(InstallationPlugin plugin) =>
    ModularCli(name: 'cx', version: '1.0.0')
      ..plugin(const DoctorPlugin())
      ..plugin(plugin);

ModularCli _cliWithDoctor(InstallationPlugin plugin) => _cliWith(plugin);
