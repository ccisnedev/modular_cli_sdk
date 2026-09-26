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

  group('hardLinkedAliasIssue', () {
    final config = _config();

    test(
      'propagates a sameFile identity-resolution failure instead of '
      'reporting no issue',
      () {
        final fileSystem =
            FakeFileSystem(
              onPath: {
                'cx': '/usr/local/bin/cx',
                'calculatrix': '/usr/local/bin/calculatrix',
              },
            )..sameFileError = Exception(
              'permission denied comparing identity',
            );

        expect(
          () => hardLinkedAliasIssue(
            fileSystem,
            config,
            '/usr/local/bin/calculatrix',
            '/usr/local/bin/cx',
          ),
          throwsA(isA<AliasIdentityCheckFailure>()),
        );
      },
    );

    test(
      'propagates a canonicalize identity-resolution failure instead of '
      'reporting no issue',
      () {
        // markHardLinked makes sameFile true through its identicalSync
        // branch, which itself calls canonicalize twice (once per path)
        // without failing. canonicalizeErrorAfterCalls lets those two
        // succeed and only the direct canonicalize calls hardLinkedAliasIssue
        // makes afterward, to compare the two paths' canonical targets, fail.
        final fileSystem =
            FakeFileSystem(
              onPath: {
                'cx': '/usr/local/bin/cx',
                'calculatrix': '/usr/local/bin/calculatrix',
              },
            )..markHardLinked(
              '/usr/local/bin/calculatrix',
              '/usr/local/bin/cx',
            );
        fileSystem.canonicalizeError = Exception(
          'permission denied resolving canonical target',
        );
        fileSystem.canonicalizeErrorAfterCalls = 2;

        expect(
          () => hardLinkedAliasIssue(
            fileSystem,
            config,
            '/usr/local/bin/calculatrix',
            '/usr/local/bin/cx',
          ),
          throwsA(isA<AliasIdentityCheckFailure>()),
        );
      },
    );

    test('returns null when either path is null', () {
      final fileSystem = FakeFileSystem();
      expect(
        hardLinkedAliasIssue(fileSystem, config, null, '/usr/local/bin/cx'),
        isNull,
      );
      expect(
        hardLinkedAliasIssue(
          fileSystem,
          config,
          '/usr/local/bin/calculatrix',
          null,
        ),
        isNull,
      );
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
      'a post-write executable-check failure is reported distinctly from a '
      'plain file-access failure',
      () async {
        final fileSystem = FakeFileSystem(onPath: {'cx': '/usr/local/bin/cx'})
          ..writeError = const CliExecutableCheckFailure(
            '/usr/local/bin/cx',
            'checking whether /usr/local/bin/cx is executable exited with '
                'unexpected code 2',
          );
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
        expect(out.output, contains('executable-check-failed'));
        expect(out.output, isNot(contains('file-access-denied')));
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

    test(
      'the executable check itself failing is a distinct, typed error from '
      'the executable not being found at all',
      () async {
        final fileSystem = FakeFileSystem(onPath: {'cx': '/usr/local/bin/cx'})
          ..resolveOnPathError = Exception('permission denied reading PATH');
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
        expect(err.output, contains('executable-check-failed'));
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
        } on io.FileSystemException catch (e) {
          markTestSkipped('could not create a symlink fixture: $e');
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

    test(
      'apply refuses to write when the install target disappears from PATH '
      'between this run\'s own plan and its own replace step',
      () async {
        final fileSystem = FakeFileSystem(onPath: {'cx': '/usr/local/bin/cx'});
        final downloader = FakeDownloader(
          bytes: const [9, 9, 9],
          onDownload: () => fileSystem.setOnPath('cx', null),
        );
        final cli = _cliWith(
          _upgradePlugin(
            releases: [_release('cli-v1.1.0', asset: 'cx-linux')],
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

        expect(code, ExitCode.genericError);
        expect(out.output, contains('install-target-changed'));
        expect(fileSystem.written, isEmpty);
      },
    );

    test(
      'apply refuses to write when the install target resolves to a '
      'different file between this run\'s own plan and its own replace '
      'step',
      () async {
        final fileSystem = FakeFileSystem(onPath: {'cx': '/usr/local/bin/cx'});
        final downloader = FakeDownloader(
          bytes: const [9, 9, 9],
          onDownload: () => fileSystem.setCanonicalTarget(
            '/usr/local/bin/cx',
            '/usr/local/bin/cx-swapped',
          ),
        );
        final cli = _cliWith(
          _upgradePlugin(
            releases: [_release('cli-v1.1.0', asset: 'cx-linux')],
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

        expect(code, ExitCode.genericError);
        expect(out.output, contains('install-target-changed'));
        expect(fileSystem.written, isEmpty);
      },
    );

    test(
      'apply refuses to write when the install target is no longer a '
      'regular file by the time of its own replace step',
      () async {
        final fileSystem = FakeFileSystem(onPath: {'cx': '/usr/local/bin/cx'});
        final downloader = FakeDownloader(
          bytes: const [9, 9, 9],
          onDownload: () => fileSystem.nonRegularFiles.add(
            '/usr/local/bin/cx',
          ),
        );
        final cli = _cliWith(
          _upgradePlugin(
            releases: [_release('cli-v1.1.0', asset: 'cx-linux')],
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

        expect(code, ExitCode.genericError);
        expect(out.output, contains('install-target-changed'));
        expect(fileSystem.written, isEmpty);
      },
    );

    test(
      '--plan fails with a typed error when the install target cannot be '
      'resolved',
      () async {
        final fileSystem = FakeFileSystem(onPath: {'cx': '/usr/local/bin/cx'})
          ..canonicalizeError = Exception('permission denied');
        final cli = _cliWith(
          _upgradePlugin(
            releases: [_release('cli-v1.1.0', asset: 'cx-linux')],
            fileSystem: fileSystem,
          ),
        );

        final err = MemorySink();
        final code = await cli.run(['upgrade', '--plan'], stderr: err);

        expect(code, ExitCode.genericError);
        expect(err.output, contains('file-access-denied'));
      },
    );

    test(
      'upgrade refuses to plan when the alias is a hard link to the '
      'executable rather than a symlink',
      () async {
        final fileSystem =
            FakeFileSystem(
              onPath: {
                'cx': '/usr/local/bin/cx',
                'calculatrix': '/usr/local/bin/calculatrix',
              },
            )..markHardLinked(
              '/usr/local/bin/calculatrix',
              '/usr/local/bin/cx',
            );
        final cli = _cliWith(
          _upgradePlugin(
            releases: [_release('cli-v1.1.0', asset: 'cx-linux')],
            fileSystem: fileSystem,
          ),
        );

        final err = MemorySink();
        final code = await cli.run(['upgrade', '--plan'], stderr: err);

        expect(code, ExitCode.genericError);
        expect(err.output, contains('alias-hard-link-unsupported'));
      },
    );

    test(
      'apply refuses to write when the alias becomes a hard link to the '
      'executable between this run\'s own plan and its own replace step',
      () async {
        final fileSystem = FakeFileSystem(
          onPath: {
            'cx': '/usr/local/bin/cx',
            'calculatrix': '/usr/local/bin/calculatrix',
          },
        );
        final downloader = FakeDownloader(
          bytes: const [9, 9, 9],
          onDownload: () => fileSystem.markHardLinked(
            '/usr/local/bin/calculatrix',
            '/usr/local/bin/cx',
          ),
        );
        final cli = _cliWith(
          _upgradePlugin(
            releases: [_release('cli-v1.1.0', asset: 'cx-linux')],
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

        expect(code, ExitCode.genericError);
        expect(out.output, contains('alias-hard-link-unsupported'));
        expect(fileSystem.written, isEmpty);
      },
    );

    test(
      'upgrade refuses to plan with a typed error when whether the alias '
      'is a hard link cannot be determined',
      () async {
        final fileSystem =
            FakeFileSystem(
              onPath: {
                'cx': '/usr/local/bin/cx',
                'calculatrix': '/usr/local/bin/calculatrix',
              },
            )..sameFileError = Exception(
              'permission denied comparing identity',
            );
        final cli = _cliWith(
          _upgradePlugin(
            releases: [_release('cli-v1.1.0', asset: 'cx-linux')],
            fileSystem: fileSystem,
          ),
        );

        final err = MemorySink();
        final code = await cli.run(['upgrade', '--plan'], stderr: err);

        expect(code, ExitCode.genericError);
        expect(err.output, contains('executable-check-failed'));
        expect(err.output, isNot(contains('alias-hard-link-unsupported')));
      },
    );

    test(
      'apply fails with a typed error when whether the alias became a hard '
      'link cannot be determined at the replace step',
      () async {
        final fileSystem = FakeFileSystem(
          onPath: {
            'cx': '/usr/local/bin/cx',
            'calculatrix': '/usr/local/bin/calculatrix',
          },
        );
        final downloader = FakeDownloader(
          bytes: const [9, 9, 9],
          onDownload: () => fileSystem.sameFileError = Exception(
            'permission denied comparing identity',
          ),
        );
        final cli = _cliWith(
          _upgradePlugin(
            releases: [_release('cli-v1.1.0', asset: 'cx-linux')],
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

        expect(code, ExitCode.genericError);
        expect(out.output, contains('executable-check-failed'));
        expect(out.output, isNot(contains('alias-hard-link-unsupported')));
        expect(fileSystem.written, isEmpty);
      },
    );

    // Round 5 finding 3: the two tests above exercise the propagation
    // through FakeFileSystem's own sameFileError seam, which already
    // worked correctly. The bug was in IoCliFileSystem itself: its
    // sameFile caught identicalSync's failure and returned false, so
    // hardLinkedAliasIssue reported "no issue" instead of propagating.
    // These two run the same plan-time and replace-step scenarios
    // through the real adapter, with only its identicalFiles seam
    // overridden, to prove the real implementation propagates too.
    test(
      'upgrade refuses to plan with a typed error when the real filesystem '
      'adapter cannot determine whether the alias is a hard link',
      () async {
        final tempDir = io.Directory.systemTemp.createTempSync(
          'upgrade_real_fs_plan_test_',
        );
        addTearDown(() {
          if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
        });
        final executablePath = _writeRealExecutableFixture(tempDir, 'cx');
        _writeRealExecutableFixture(tempDir, 'calculatrix');

        final fileSystem = _RealFileSystemWithIdenticalFilesSeam(
          pathDirectories: [tempDir.path],
        )..identicalFilesError = Exception(
          'permission denied comparing identity',
        );

        final cli = _cliWith(
          _upgradePlugin(
            releases: [_release('cli-v1.1.0', asset: 'cx-linux')],
            fileSystem: fileSystem,
          ),
        );

        final err = MemorySink();
        final code = await cli.run(['upgrade', '--plan'], stderr: err);

        expect(code, ExitCode.genericError);
        expect(err.output, contains('executable-check-failed'));
        expect(err.output, isNot(contains('alias-hard-link-unsupported')));
        expect(io.File(executablePath).existsSync(), isTrue);
      },
    );

    test(
      'apply fails with a typed error when the real filesystem adapter '
      'cannot determine whether the alias became a hard link at the '
      'replace step',
      () async {
        final tempDir = io.Directory.systemTemp.createTempSync(
          'upgrade_real_fs_replace_test_',
        );
        addTearDown(() {
          if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
        });
        _writeRealExecutableFixture(tempDir, 'cx');
        _writeRealExecutableFixture(tempDir, 'calculatrix');

        final fileSystem = _RealFileSystemWithIdenticalFilesSeam(
          pathDirectories: [tempDir.path],
        );
        final downloader = FakeDownloader(
          bytes: const [9, 9, 9],
          onDownload: () => fileSystem.identicalFilesError = Exception(
            'permission denied comparing identity',
          ),
        );

        final cli = _cliWith(
          _upgradePlugin(
            releases: [_release('cli-v1.1.0', asset: 'cx-linux')],
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

        expect(code, ExitCode.genericError);
        expect(out.output, contains('executable-check-failed'));
        expect(out.output, isNot(contains('alias-hard-link-unsupported')));
      },
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
      'the executable check itself failing is a distinct, typed error from '
      'nothing being on PATH',
      () async {
        final fileSystem = FakeFileSystem(onPath: {'cx': '/usr/local/bin/cx'})
          ..resolveOnPathError = Exception('permission denied reading PATH');
        final cli = _cliWith(_upgradePlugin(fileSystem: fileSystem));

        final err = MemorySink();
        final code = await cli.run([
          'uninstall',
          '--apply',
          '--autoapprove',
        ], stderr: err);

        expect(code, ExitCode.genericError);
        expect(err.output, contains('executable-check-failed'));
      },
    );

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

    test('on Windows, the running executable is moved aside and a cleanup '
        'worker is started to remove it once this process exits', () async {
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
      expect(processLauncher.startedCleanupWorkers, hasLength(1));
      final payload = processLauncher.startedCleanupWorkers.single;
      // No part of the payload is interpolated into a script; it travels as
      // plain JSON values on the worker's stdin instead, so there is nothing
      // here for a path to escape or break out of.
      expect(payload['parentPid'], 4242);
      expect(payload['paths'], ['/usr/local/bin/cx.uninstall-4242.old']);
      // No timeoutMs field: the worker waits for the parent to exit with
      // no time limit once it arms deletion, so there is nothing here to
      // configure a cap for.
      expect(payload.containsKey('timeoutMs'), isFalse);
      // No silent success: the plan says explicitly that removal is
      // deferred, rather than implying the file is already gone.
      expect(
        out.output,
        contains('/usr/local/bin/cx will be removed when this process exits'),
      );
      // Honest reporting: the path is scheduled, not removed. Nothing on
      // disk has actually been deleted yet at the point this output is
      // printed.
      expect(out.output, contains('scheduled: [/usr/local/bin/cx]'));
      expect(out.output, isNot(contains('removed: [/usr/local/bin/cx]')));
    });

    test(
      'the cleanup worker payload is not shell-escaped: paths with spaces, '
      'apostrophes, %, &, ! and parentheses travel through unchanged',
      () async {
        const trickyPath =
            "/usr/local/bin/cx that's (weird) 100% & loud!.exe";
        final fileSystem = FakeFileSystem(onPath: {'cx': trickyPath});
        final processLauncher = FakeProcessLauncher(pid: 4242);
        final cli = _cliWith(
          _upgradePlugin(
            fileSystem: fileSystem,
            platform: const FakePlatform('windows'),
            processLauncher: processLauncher,
          ),
        );

        final code = await cli.run([
          'uninstall',
          '--apply',
          '--autoapprove',
        ], stdout: MemorySink());

        expect(code, ExitCode.ok);
        final payload = processLauncher.startedCleanupWorkers.single;
        expect(payload['paths'], ['$trickyPath.uninstall-4242.old']);
      },
    );

    // Round 5 finding 4 added a warning startCleanupWorker returned on
    // success when its own private-directory cleanup failed, and this step
    // attached it to the schedule outcome rather than discarding it. Round
    // 6 finding 1 removed that attempt entirely: private-directory cleanup
    // after a successful claim now belongs to the worker itself (see
    // cli_process_launcher_test.dart), so startCleanupWorker never returns
    // a warning on success any more, and this step has nothing left to
    // attach.

    test('on Windows, if the cleanup worker cannot be started, uninstall '
        'fails with cleanup-start-failed instead of a silent success', () async {
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
      expect(out.output, contains('cleanup-start-failed'));
      // The rename already happened; the failure message says where the
      // file ended up rather than leaving it unaccounted for.
      expect(out.output, contains('/usr/local/bin/cx.uninstall-4242.old'));
    });

    test('on Windows, if the cleanup worker starts but never confirms it is '
        'ready, uninstall fails with cleanup-start-failed', () async {
      final fileSystem = FakeFileSystem(onPath: {'cx': '/usr/local/bin/cx'});
      final processLauncher = FakeProcessLauncher(readyLine: 'not ready yet');
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
      expect(out.output, contains('cleanup-start-failed'));
    });

    // Round 8 finding 1: a startCleanupWorker failure that leaves it unknown
    // whether the worker armed deletion or this process revoked its claim
    // first is not the same failure as one where the worker was never
    // reachable at all. This step maps it to its own distinct error id
    // rather than folding it into cleanup-start-failed, and the message
    // tells the operator the worker may still delete the renamed file
    // later, so they know not to delete it by hand.
    test('on Windows, if it cannot be determined whether the cleanup worker '
        'armed deletion or this process revoked its claim first, uninstall '
        'fails with cleanup-outcome-unknown rather than cleanup-start-failed',
        () async {
      final fileSystem = FakeFileSystem(onPath: {'cx': '/usr/local/bin/cx'});
      final processLauncher = FakeProcessLauncher(
        startError: CliCleanupOutcomeUnknown(
          'renaming the accepted marker kept failing unexpectedly without '
          'resolving either way',
        ),
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
      expect(out.output, contains('cleanup-outcome-unknown'));
      expect(out.output, isNot(contains('cleanup-start-failed')));
      expect(out.output, contains('/usr/local/bin/cx.uninstall-4242.old'));
      expect(out.output, contains('may still'));
    });

    test(
      'a resolution failure while comparing the alias to the executable '
      'reports file-access-denied rather than crashing the run',
      () async {
        // sameFile resolves both paths through canonicalize before comparing
        // them; a canonicalize that cannot resolve one of them (a broken
        // symlink chain, permission denied partway through) must not be
        // allowed to escape as a raw, unhandled exception.
        final fileSystem = FakeFileSystem(
          onPath: {
            'cx': '/usr/local/bin/cx',
            'calculatrix': '/usr/local/bin/calculatrix',
          },
        )..canonicalizeError = Exception('too many levels of symbolic links');
        final cli = _cliWith(_upgradePlugin(fileSystem: fileSystem));

        final err = MemorySink();
        final code = await cli.run([
          'uninstall',
          '--apply',
          '--autoapprove',
        ], stderr: err);

        expect(code, ExitCode.genericError);
        expect(err.output, contains('file-access-denied'));
      },
    );

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
        } on io.FileSystemException catch (e) {
          markTestSkipped('could not create a symlink fixture: $e');
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

    test(
      'the binary check itself failing reports that it could not check, '
      'not that the binary was not found',
      () async {
        final fileSystem = FakeFileSystem(onPath: {'cx': '/usr/local/bin/cx'})
          ..resolveOnPathError = Exception('permission denied reading PATH');
        final cli = _cliWithDoctor(_upgradePlugin(fileSystem: fileSystem));

        final out = MemorySink();
        final code = await cli.run(['doctor'], stdout: out);

        expect(code, ExitCode.configError);
        expect(out.output, contains('could not check'));
        expect(out.output, isNot(contains('was not found on PATH')));
      },
    );

    test(
      'the alias check itself failing reports that it could not check, not '
      'that the alias was not found',
      () async {
        final fileSystem = FakeFileSystem(
          onPath: {
            'cx': '/usr/local/bin/cx',
            'calculatrix': '/usr/local/bin/cx',
          },
        )..resolveOnPathError = Exception('permission denied reading PATH');
        final cli = _cliWithDoctor(_upgradePlugin(fileSystem: fileSystem));

        final out = MemorySink();
        final code = await cli.run(['doctor'], stdout: out);

        expect(code, ExitCode.configError);
        expect(out.output, contains('could not check'));
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

    test(
      'an alias that is a hard link to the binary, not a symlink, is a '
      'doctor error',
      () async {
        final fileSystem =
            FakeFileSystem(
              onPath: {
                'cx': '/usr/local/bin/cx',
                'calculatrix': '/usr/local/bin/calculatrix',
              },
            )..markHardLinked(
              '/usr/local/bin/calculatrix',
              '/usr/local/bin/cx',
            );
        final cli = _cliWithDoctor(_upgradePlugin(fileSystem: fileSystem));

        final out = MemorySink();
        final code = await cli.run(['doctor'], stdout: out);

        expect(code, ExitCode.configError);
        expect(out.output, contains('hard link'));
      },
    );

    test(
      'the alias identity check itself failing is a doctor error, not a '
      'silent ok',
      () async {
        final fileSystem =
            FakeFileSystem(
              onPath: {
                'cx': '/usr/local/bin/cx',
                'calculatrix': '/usr/local/bin/calculatrix',
              },
            )..sameFileError = Exception(
              'permission denied comparing identity',
            );
        final cli = _cliWithDoctor(_upgradePlugin(fileSystem: fileSystem));

        final out = MemorySink();
        final code = await cli.run(['doctor'], stdout: out);

        expect(code, ExitCode.configError);
        expect(out.output, contains('could not check'));
      },
    );

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

CliInstallationConfig _config({String tagPrefix = 'cli-v'}) =>
    CliInstallationConfig(
      repository: 'ccisnedev/calculatrix',
      tagPrefix: tagPrefix,
      executable: 'cx',
      alias: 'calculatrix',
      assets: const {
        'linux': 'cx-linux',
        'macos': 'cx-macos',
        'windows': 'cx-windows.exe',
      },
    );

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

/// Writes an executable fixture named [name] into [dir], naming and
/// permissioning it the way [IoCliFileSystem.resolveOnPath] requires it to
/// be found: a `.exe` extension on Windows (matched by the default
/// `PATHEXT` candidate list), an execute bit on POSIX (checked by the real
/// `/bin/test` or `/usr/bin/test` through [IoCliExecutableChecker]).
/// Returns the full path written.
String _writeRealExecutableFixture(io.Directory dir, String name) {
  final path =
      '${dir.path}${io.Platform.pathSeparator}'
      '${io.Platform.isWindows ? '$name.exe' : name}';
  io.File(path).writeAsBytesSync([1, 2, 3]);
  if (!io.Platform.isWindows) {
    io.Process.runSync('chmod', ['+x', path]);
  }
  return path;
}

/// A real [IoCliFileSystem], limited to [pathDirectories] for PATH
/// resolution, whose [identicalFiles] seam can be told to throw on demand.
/// Used to prove that the real adapter itself, not just FakeFileSystem's
/// own sameFileError seam, propagates an identicalFiles failure through
/// sameFile instead of reporting "no issue".
class _RealFileSystemWithIdenticalFilesSeam extends IoCliFileSystem {
  _RealFileSystemWithIdenticalFilesSeam({
    required List<String> pathDirectories,
  }) : super(pathDirectories: pathDirectories);

  Object? identicalFilesError;

  @override
  bool identicalFiles(String a, String b) {
    final error = identicalFilesError;
    if (error != null) throw error;
    return super.identicalFiles(a, b);
  }
}
