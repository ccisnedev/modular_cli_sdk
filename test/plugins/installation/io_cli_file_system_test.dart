/// Real filesystem and `PATH` behaviour `IoCliFileSystem` implements: an
/// atomic self-replacing write, PATH resolution that skips a candidate the
/// platform could not actually execute, and canonical-path identity.
/// Exercised against a temporary directory rather than through a fake,
/// because these are facts about the machine a fake cannot stand in for.
library;

import 'dart:io' as io;

import 'package:modular_cli_sdk/modular_cli_sdk.dart';
import 'package:test/test.dart';

void main() {
  late io.Directory tempDir;

  setUp(() {
    tempDir = io.Directory.systemTemp.createTempSync(
      'io_cli_file_system_test_',
    );
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  String pathIn(io.Directory dir, String name) =>
      '${dir.path}${io.Platform.pathSeparator}$name';

  group('writeExecutable', () {
    test('writes the given bytes to a new file', () async {
      const fs = IoCliFileSystem();
      final path = pathIn(tempDir, 'cx');

      await fs.writeExecutable(path, [1, 2, 3], revalidate: () async {});

      expect(io.File(path).readAsBytesSync(), [1, 2, 3]);
    });

    test('replaces an existing file rather than appending to it', () async {
      const fs = IoCliFileSystem();
      final path = pathIn(tempDir, 'cx');
      io.File(path).writeAsBytesSync([9, 9, 9, 9, 9]);

      await fs.writeExecutable(path, [1, 2, 3], revalidate: () async {});

      expect(io.File(path).readAsBytesSync(), [1, 2, 3]);
    });

    test('leaves no temporary file behind after a successful write', () async {
      const fs = IoCliFileSystem();
      final path = pathIn(tempDir, 'cx');
      io.File(path).writeAsBytesSync([9, 9, 9]);

      await fs.writeExecutable(path, [1, 2, 3], revalidate: () async {});

      final leftovers = tempDir
          .listSync()
          .where((e) => e.path != path)
          .toList();
      expect(leftovers, isEmpty);
    });

    test(
      'calls revalidate after staging the new content but before '
      'committing it into place',
      () async {
        const fs = IoCliFileSystem();
        final path = pathIn(tempDir, io.Platform.isWindows ? 'cx.exe' : 'cx');
        io.File(path).writeAsBytesSync([9, 9, 9]);

        List<int>? pathContentAtRevalidateTime;
        int? stagedFileCountAtRevalidateTime;

        await fs.writeExecutable(
          path,
          [1, 2, 3],
          revalidate: () async {
            pathContentAtRevalidateTime = io.File(path).readAsBytesSync();
            stagedFileCountAtRevalidateTime = tempDir
                .listSync()
                .where((e) => e.path != path)
                .length;
          },
        );

        expect(
          pathContentAtRevalidateTime,
          [9, 9, 9],
          reason:
              'revalidate must see the pre-commit content: the destructive '
              'step that replaces it has not run yet',
        );
        expect(
          stagedFileCountAtRevalidateTime,
          1,
          reason:
              'the new content must already be staged to a temporary file '
              'by the time revalidate runs',
        );
        expect(io.File(path).readAsBytesSync(), [1, 2, 3]);
      },
    );

    test(
      'nothing is committed and no temp file is left behind when '
      'revalidate throws',
      () async {
        const fs = IoCliFileSystem();
        final path = pathIn(tempDir, io.Platform.isWindows ? 'cx.exe' : 'cx');
        io.File(path).writeAsBytesSync([9, 9, 9]);

        await expectLater(
          fs.writeExecutable(
            path,
            [1, 2, 3],
            revalidate: () async {
              throw StateError('target changed since this plan was built');
            },
          ),
          throwsA(isA<StateError>()),
        );

        expect(io.File(path).readAsBytesSync(), [9, 9, 9]);
        final leftovers = tempDir
            .listSync()
            .where((e) => e.path != path)
            .toList();
        expect(leftovers, isEmpty);
      },
    );

    test(
      'sets the execute bit',
      () async {
        const fs = IoCliFileSystem();
        final path = pathIn(tempDir, 'cx');

        await fs.writeExecutable(path, [1, 2, 3], revalidate: () async {});

        final mode = io.File(path).statSync().mode;
        expect(
          mode & 0x49,
          isNot(0),
          reason: 'expected an owner/group/other execute bit to be set',
        );
      },
      skip: io.Platform.isWindows
          ? 'no execute bit to check on Windows'
          : false,
    );

    test(
      'stays readable through a handle opened before the write',
      () async {
        // Evidence that the write does not require the old file to be closed
        // first: a real self-upgrade replaces a target the running process
        // itself still has open (mapped for execution). Opening a read
        // handle before writeExecutable stands in for that without spawning
        // a process. rename(2) never disturbs a handle already open on the
        // old inode, which is exactly why it avoids Linux's ETXTBSY where a
        // truncate-then-write-in-place would not.
        const fs = IoCliFileSystem();
        final path = pathIn(tempDir, 'cx');
        io.File(path).writeAsBytesSync([9, 9, 9]);
        final handle = io.File(path).openSync(mode: io.FileMode.read);

        try {
          await fs.writeExecutable(path, [1, 2, 3], revalidate: () async {});
          expect(handle.readSync(3), [9, 9, 9]);
        } finally {
          handle.closeSync();
        }

        expect(io.File(path).readAsBytesSync(), [1, 2, 3]);
      },
      skip: io.Platform.isWindows ? 'POSIX rename semantics only' : false,
    );

    test(
      'replaces the current target on Windows even though it already exists',
      () async {
        const fs = IoCliFileSystem();
        final path = pathIn(tempDir, 'cx.exe');
        io.File(path).writeAsBytesSync([9, 9, 9]);

        await fs.writeExecutable(path, [1, 2, 3], revalidate: () async {});

        expect(io.File(path).readAsBytesSync(), [1, 2, 3]);
      },
      skip: io.Platform.isWindows ? false : 'Windows-specific replace path',
    );

    test(
      'still blames chmod with a FileSystemException when the post-write '
      'check reports exit code 1 (not executable)',
      () async {
        final fs = IoCliFileSystem(
          executableChecker: _FixedExecutableChecker(exitCode: 1),
        );
        final path = pathIn(tempDir, 'cx');

        await expectLater(
          fs.writeExecutable(path, [1, 2, 3], revalidate: () async {}),
          throwsA(isA<io.FileSystemException>()),
        );
      },
      skip: io.Platform.isWindows
          ? 'POSIX chmod/executable-check path only'
          : false,
    );

    test(
      'a post-write check exit code other than 0 or 1 is a typed '
      'CliExecutableCheckFailure, not the chmod-blamed error',
      () async {
        final fs = IoCliFileSystem(
          executableChecker: _FixedExecutableChecker(exitCode: 2),
        );
        final path = pathIn(tempDir, 'cx');

        await expectLater(
          fs.writeExecutable(path, [1, 2, 3], revalidate: () async {}),
          throwsA(isA<CliExecutableCheckFailure>()),
        );
      },
      skip: io.Platform.isWindows
          ? 'POSIX chmod/executable-check path only'
          : false,
    );

    test(
      'the post-write check failing to start at all is a typed '
      'CliExecutableCheckFailure, not the chmod-blamed error',
      () async {
        final fs = IoCliFileSystem(
          executableChecker: _FixedExecutableChecker(
            startupError: Exception('no such file or directory'),
          ),
        );
        final path = pathIn(tempDir, 'cx');

        await expectLater(
          fs.writeExecutable(path, [1, 2, 3], revalidate: () async {}),
          throwsA(isA<CliExecutableCheckFailure>()),
        );
      },
      skip: io.Platform.isWindows
          ? 'POSIX chmod/executable-check path only'
          : false,
    );
  });

  group('writeExecutable (Windows rename-failure restore)', () {
    test(
      'restores the previous executable when the final rename into place fails',
      () async {
        final fs = _FailingRenameFileSystem();
        final path = pathIn(tempDir, 'cx.exe');
        io.File(path).writeAsBytesSync([9, 9, 9]);

        await expectLater(
          fs.writeExecutable(path, [1, 2, 3], revalidate: () async {}),
          throwsA(isA<io.FileSystemException>()),
        );

        // The installation is restored, not gone: the whole point of
        // keeping the backup until the rename succeeds is that a failed
        // rename must not leave [path] missing.
        expect(io.File(path).readAsBytesSync(), [9, 9, 9]);
      },
      skip: io.Platform.isWindows ? false : 'Windows-specific replace path',
    );

    test(
      'leaves no leftover backup or temp file once the restore has run',
      () async {
        final fs = _FailingRenameFileSystem();
        final path = pathIn(tempDir, 'cx.exe');
        io.File(path).writeAsBytesSync([9, 9, 9]);

        await expectLater(
          fs.writeExecutable(path, [1, 2, 3], revalidate: () async {}),
          throwsA(isA<io.FileSystemException>()),
        );

        final leftovers = tempDir
            .listSync()
            .where((e) => e.path != path)
            .toList();
        expect(leftovers, isEmpty);
      },
      skip: io.Platform.isWindows ? false : 'Windows-specific replace path',
    );
  });

  group('delete', () {
    test('deletes an ordinary file', () async {
      const fs = IoCliFileSystem();
      final path = pathIn(tempDir, 'plain');
      io.File(path).writeAsBytesSync([1]);

      await fs.delete(path);

      expect(io.File(path).existsSync(), isFalse);
    });

    test(
      'deletes a dangling symlink, which File.delete alone cannot',
      () async {
        final target = pathIn(tempDir, 'target');
        io.File(target).writeAsBytesSync([1]);
        final linkPath = pathIn(tempDir, 'link');
        try {
          io.Link(linkPath).createSync(target);
        } on io.FileSystemException catch (e) {
          markTestSkipped('could not create a symlink fixture: $e');
          return;
        }
        io.File(target).deleteSync();

        const fs = IoCliFileSystem();
        // dart:io's File.delete resolves the path through a stat before
        // removing it, which fails on a dangling symlink even though
        // unlinking the symlink entry itself has nothing to do with
        // whether its target exists.
        await fs.delete(linkPath);

        expect(io.Link(linkPath).existsSync(), isFalse);
      },
      skip: io.Platform.isWindows ? 'POSIX symlink semantics only' : false,
    );

    test(
      'deletes a valid symlink itself, leaving its target in place',
      () async {
        final target = pathIn(tempDir, 'target');
        io.File(target).writeAsBytesSync([1]);
        final linkPath = pathIn(tempDir, 'link');
        try {
          io.Link(linkPath).createSync(target);
        } on io.FileSystemException catch (e) {
          markTestSkipped('could not create a symlink fixture: $e');
          return;
        }

        const fs = IoCliFileSystem();
        await fs.delete(linkPath);

        expect(io.Link(linkPath).existsSync(), isFalse);
        expect(io.File(target).existsSync(), isTrue);
      },
      skip: io.Platform.isWindows ? 'POSIX symlink semantics only' : false,
    );
  });

  group('resolveOnPath', () {
    test('finds a name in an injected PATH directory', () {
      final binDir = io.Directory(pathIn(tempDir, 'bin'))..createSync();
      final exeName = io.Platform.isWindows ? 'cx.exe' : 'cx';
      final exePath = pathIn(binDir, exeName);
      io.File(exePath).writeAsBytesSync([1]);
      if (!io.Platform.isWindows) {
        io.Process.runSync('chmod', ['+x', exePath]);
      }

      final fs = IoCliFileSystem(pathDirectories: [binDir.path]);
      // Compared case-insensitively on Windows: the candidate name is built
      // from the real machine's PATHEXT (whatever casing it lists), not
      // from the casing the test happened to create the file with, and
      // Windows treats the two as the same path either way.
      expect(fs.resolveOnPath('cx')?.toLowerCase(), exePath.toLowerCase());
    });

    test('returns null when nothing on the injected PATH matches', () {
      final binDir = io.Directory(pathIn(tempDir, 'bin'))..createSync();
      final fs = IoCliFileSystem(pathDirectories: [binDir.path]);
      expect(fs.resolveOnPath('cx'), isNull);
    });

    test(
      'skips an earlier PATH entry that exists but is not executable',
      () {
        final firstDir = io.Directory(pathIn(tempDir, 'first'))..createSync();
        final secondDir = io.Directory(pathIn(tempDir, 'second'))..createSync();
        final nonExecutable = pathIn(firstDir, 'cx');
        final executable = pathIn(secondDir, 'cx');
        io.File(nonExecutable).writeAsBytesSync([1]);
        io.File(executable).writeAsBytesSync([1]);
        io.Process.runSync('chmod', ['-x', nonExecutable]);
        io.Process.runSync('chmod', ['+x', executable]);

        final fs = IoCliFileSystem(
          pathDirectories: [firstDir.path, secondDir.path],
        );
        expect(fs.resolveOnPath('cx'), executable);
      },
      skip: io.Platform.isWindows ? 'POSIX execute bit only' : false,
    );

    test(
      'finds a name only under an extension PATHEXT lists',
      () {
        final dir = io.Directory(pathIn(tempDir, 'bin'))..createSync();
        final notExecutable = pathIn(dir, 'cx.txt');
        final executable = pathIn(dir, 'cx.exe');
        io.File(notExecutable).writeAsBytesSync([1]);
        io.File(executable).writeAsBytesSync([1]);

        final fs = IoCliFileSystem(pathDirectories: [dir.path]);
        expect(fs.resolveOnPath('cx')?.toLowerCase(), executable.toLowerCase());
      },
      skip: io.Platform.isWindows ? false : 'Windows PATHEXT only',
    );

    test(
      'rejects a file whose only execute bit belongs to someone else',
      () {
        final binDir = io.Directory(pathIn(tempDir, 'bin'))..createSync();
        final path = pathIn(binDir, 'cx');
        io.File(path).writeAsBytesSync([1]);
        // 0641: owner rw-, group r--, other --x. The file is owned by this
        // process (it just created it), so the only bit that matters is the
        // owner bit, which is unset here even though an execute bit is set
        // somewhere in the mode.
        io.Process.runSync('chmod', ['0641', path]);

        final fs = IoCliFileSystem(pathDirectories: [binDir.path]);
        expect(fs.resolveOnPath('cx'), isNull);
      },
      skip: io.Platform.isWindows ? 'POSIX execute bit only' : false,
    );

    test(
      'accepts a file the owner may execute (0700)',
      () {
        final binDir = io.Directory(pathIn(tempDir, 'bin'))..createSync();
        final path = pathIn(binDir, 'cx');
        io.File(path).writeAsBytesSync([1]);
        io.Process.runSync('chmod', ['0700', path]);

        final fs = IoCliFileSystem(pathDirectories: [binDir.path]);
        expect(fs.resolveOnPath('cx'), path);
      },
      skip: io.Platform.isWindows ? 'POSIX execute bit only' : false,
    );

    test(
      'finds a name behind a symlink to an executable',
      () {
        final binDir = io.Directory(pathIn(tempDir, 'bin'))..createSync();
        final real = pathIn(binDir, 'cx-real');
        io.File(real).writeAsBytesSync([1]);
        io.Process.runSync('chmod', ['+x', real]);
        final linkPath = pathIn(binDir, 'cx');
        try {
          io.Link(linkPath).createSync(real);
        } on io.FileSystemException catch (e) {
          fail(
            'fixture setup failed: could not create a symlink for this '
            'test to exercise ($e)',
          );
        }

        final fs = IoCliFileSystem(pathDirectories: [binDir.path]);
        expect(fs.resolveOnPath('cx'), linkPath);
      },
      skip: io.Platform.isWindows ? 'POSIX symlink semantics only' : false,
    );

    test(
      'a checker that reports the candidate is not executable (exit 1) is '
      'skipped in favor of the next PATH entry',
      () {
        final firstDir = io.Directory(pathIn(tempDir, 'first'))..createSync();
        final secondDir = io.Directory(pathIn(tempDir, 'second'))
          ..createSync();
        final notExecutable = pathIn(firstDir, 'cx');
        final executable = pathIn(secondDir, 'cx');
        io.File(notExecutable).writeAsBytesSync([1]);
        io.File(executable).writeAsBytesSync([1]);

        final fs = IoCliFileSystem(
          pathDirectories: [firstDir.path, secondDir.path],
          executableChecker: _FakeExecutableChecker(
            exitCodes: {notExecutable: 1, executable: 0},
          ),
        );
        expect(fs.resolveOnPath('cx'), executable);
      },
      skip: io.Platform.isWindows
          ? 'the executable checker is a POSIX-only concern'
          : false,
    );

    test(
      'a checker exit code other than 0 or 1 is a typed failure, not a '
      'silent skip',
      () {
        final binDir = io.Directory(pathIn(tempDir, 'bin'))..createSync();
        final path = pathIn(binDir, 'cx');
        io.File(path).writeAsBytesSync([1]);

        final fs = IoCliFileSystem(
          pathDirectories: [binDir.path],
          executableChecker: _FakeExecutableChecker(exitCodes: {path: 2}),
        );
        expect(
          () => fs.resolveOnPath('cx'),
          throwsA(isA<CliExecutableCheckFailure>()),
        );
      },
      skip: io.Platform.isWindows
          ? 'the executable checker is a POSIX-only concern'
          : false,
    );

    test(
      'the checker failing to start at all is a typed failure',
      () {
        final binDir = io.Directory(pathIn(tempDir, 'bin'))..createSync();
        final path = pathIn(binDir, 'cx');
        io.File(path).writeAsBytesSync([1]);

        final fs = IoCliFileSystem(
          pathDirectories: [binDir.path],
          executableChecker: _FakeExecutableChecker(
            startupError: {path: Exception('no such file or directory')},
          ),
        );
        expect(
          () => fs.resolveOnPath('cx'),
          throwsA(isA<CliExecutableCheckFailure>()),
        );
      },
      skip: io.Platform.isWindows
          ? 'the executable checker is a POSIX-only concern'
          : false,
    );
  });

  group('sameFile', () {
    test('a path is the same file as itself', () {
      const fs = IoCliFileSystem();
      final path = pathIn(tempDir, 'cx');
      io.File(path).writeAsBytesSync([1]);
      expect(fs.sameFile(path, path), isTrue);
    });

    test('two unrelated files are not the same file', () {
      const fs = IoCliFileSystem();
      final a = pathIn(tempDir, 'a');
      final b = pathIn(tempDir, 'b');
      io.File(a).writeAsBytesSync([1]);
      io.File(b).writeAsBytesSync([1]);
      expect(fs.sameFile(a, b), isFalse);
    });

    test(
      'a symlink is the same file as its target',
      () {
        final target = pathIn(tempDir, 'real');
        io.File(target).writeAsBytesSync([1]);
        final linkPath = pathIn(tempDir, 'link');
        try {
          io.Link(linkPath).createSync(target);
        } on io.FileSystemException catch (e) {
          markTestSkipped('could not create a symlink fixture: $e');
          return;
        }

        const fs = IoCliFileSystem();
        expect(fs.sameFile(linkPath, target), isTrue);
      },
      skip: io.Platform.isWindows ? 'POSIX symlink semantics only' : false,
    );

    test('a hard link is the same file as its target, even though canonicalize '
        'alone disagrees', () {
      final target = pathIn(tempDir, 'real');
      io.File(target).writeAsBytesSync([1]);
      final hardLinkPath = pathIn(tempDir, 'hardlink');
      final result = io.Process.runSync('ln', [target, hardLinkPath]);
      if (result.exitCode != 0) {
        markTestSkipped(
          'could not create a hard link fixture: ln exited '
          '${result.exitCode}: ${result.stderr}',
        );
        return;
      }

      const fs = IoCliFileSystem();
      // canonicalize only resolves symlinks: a hard link has no symlink
      // target to resolve through, so it reports these as two different
      // files even though they are the same inode.
      expect(fs.canonicalize(hardLinkPath), isNot(fs.canonicalize(target)));
      expect(fs.sameFile(hardLinkPath, target), isTrue);
    }, skip: io.Platform.isWindows ? 'POSIX hard link semantics only' : false);

    // Round 5 finding 3: identicalFiles is the one seam sameFile has for
    // exactly this call (the same shape as renameIntoPlace's own seam
    // above), because there is no portable way to make a real
    // identicalSync call fail on command. A caller (hardLinkedAliasIssue,
    // UninstallCommand.steps) that cannot tell whether two paths are the
    // same file must be told that, not handed a false "different files"
    // that reports a hard-linked alias, or an alias that could not be
    // checked at all, as no issue.
    test(
      'propagates an identicalFiles failure instead of reporting no issue',
      () {
        final a = pathIn(tempDir, 'a');
        final b = pathIn(tempDir, 'b');
        io.File(a).writeAsBytesSync([1]);
        io.File(b).writeAsBytesSync([1]);

        final fs = _ThrowingIdenticalFilesFileSystem(
          io.FileSystemException('permission denied comparing identity'),
        );

        expect(
          () => fs.sameFile(a, b),
          throwsA(isA<io.FileSystemException>()),
        );
      },
    );
  });

  group('canonicalize', () {
    test('resolves a symlink to the same canonical path as its target', () {
      final target = pathIn(tempDir, 'real');
      io.File(target).writeAsBytesSync([1]);
      final linkPath = pathIn(tempDir, 'link');

      try {
        io.Link(linkPath).createSync(target);
      } on io.FileSystemException catch (e) {
        // Creating a symlink can require a privilege this test process does
        // not have (notably on Windows without Developer Mode enabled); the
        // platform rule under test does not apply in that environment, and
        // that is recorded as an explicit skip rather than a silent pass.
        markTestSkipped('could not create a symlink fixture: $e');
        return;
      }

      const fs = IoCliFileSystem();
      expect(fs.canonicalize(linkPath), fs.canonicalize(target));
    });

    // Strict on purpose: a resolution failure swallowed here and papered
    // over with the original path is exactly how an upgrade ends up
    // replacing a symlink itself instead of what it points at. The caller
    // (UpgradeCommand.steps, UninstallCommand.steps) is the one that turns
    // this into a file-access-denied failure; canonicalize's own job is
    // only to surface the failure rather than hide it.
    test(
      'propagates the failure rather than returning the path itself when '
      'nothing exists there',
      () {
        const fs = IoCliFileSystem();
        final missing = pathIn(tempDir, 'does-not-exist');
        expect(
          () => fs.canonicalize(missing),
          throwsA(isA<io.FileSystemException>()),
        );
      },
    );

    test(
      'propagates the failure for a dangling symlink instead of returning '
      'the link path itself',
      () {
        final target = pathIn(tempDir, 'real');
        io.File(target).writeAsBytesSync([1]);
        final linkPath = pathIn(tempDir, 'link');
        try {
          io.Link(linkPath).createSync(target);
        } on io.FileSystemException catch (e) {
          markTestSkipped('could not create a symlink fixture: $e');
          return;
        }
        io.File(target).deleteSync();

        const fs = IoCliFileSystem();
        expect(
          () => fs.canonicalize(linkPath),
          throwsA(isA<io.FileSystemException>()),
        );
      },
      skip: io.Platform.isWindows ? 'POSIX symlink semantics only' : false,
    );
  });
}

/// Fails the final rename-into-place step of a Windows self-replacing write,
/// without needing a second process to actually hold the target file open.
/// [IoCliFileSystem.renameIntoPlace] exists as a public, overridable seam for
/// exactly this: exercising the backup-restore-on-failure path from a test.
class _FailingRenameFileSystem extends IoCliFileSystem {
  const _FailingRenameFileSystem();

  @override
  Future<void> renameIntoPlace(io.File temp, String path) async {
    throw io.FileSystemException('simulated rename failure', path);
  }
}

/// An injected [CliExecutableChecker] whose answer for each path is fixed by
/// the test, in place of actually shelling out to `/bin/test` or
/// `/usr/bin/test`: exit codes, or a startup failure, per path.
class _FakeExecutableChecker implements CliExecutableChecker {
  _FakeExecutableChecker({
    this.exitCodes = const {},
    this.startupError = const {},
  });

  final Map<String, int> exitCodes;
  final Map<String, Object> startupError;

  @override
  int exitCodeFor(String path) {
    final error = startupError[path];
    if (error != null) throw error;
    final exitCode = exitCodes[path];
    if (exitCode == null) {
      throw StateError('no exit code configured for $path in this test');
    }
    return exitCode;
  }
}

/// An injected [CliExecutableChecker] that answers the same way for
/// whatever path it is asked about, in place of a fixed per-path map: the
/// temporary file [IoCliFileSystem.writeExecutable] checks has a name built
/// from the current pid and a microsecond timestamp, which a test cannot
/// predict ahead of the call.
class _FixedExecutableChecker implements CliExecutableChecker {
  _FixedExecutableChecker({this.exitCode, this.startupError});

  final int? exitCode;
  final Object? startupError;

  @override
  int exitCodeFor(String path) {
    final error = startupError;
    if (error != null) throw error;
    final code = exitCode;
    if (code == null) {
      throw StateError('no exit code configured for this test');
    }
    return code;
  }
}

/// A real [IoCliFileSystem] whose [identicalFiles] seam always throws
/// [error] in place of running the real identicalSync check. Overriding
/// this one method, rather than [sameFile] itself, exercises sameFile's
/// own propagation of that failure through the real adapter, not a
/// reimplementation of sameFile's logic in a fake.
class _ThrowingIdenticalFilesFileSystem extends IoCliFileSystem {
  _ThrowingIdenticalFilesFileSystem(this.error);

  final Object error;

  @override
  bool identicalFiles(String a, String b) => throw error;
}
