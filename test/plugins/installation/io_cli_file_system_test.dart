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

      await fs.writeExecutable(path, [1, 2, 3]);

      expect(io.File(path).readAsBytesSync(), [1, 2, 3]);
    });

    test('replaces an existing file rather than appending to it', () async {
      const fs = IoCliFileSystem();
      final path = pathIn(tempDir, 'cx');
      io.File(path).writeAsBytesSync([9, 9, 9, 9, 9]);

      await fs.writeExecutable(path, [1, 2, 3]);

      expect(io.File(path).readAsBytesSync(), [1, 2, 3]);
    });

    test('leaves no temporary file behind after a successful write', () async {
      const fs = IoCliFileSystem();
      final path = pathIn(tempDir, 'cx');
      io.File(path).writeAsBytesSync([9, 9, 9]);

      await fs.writeExecutable(path, [1, 2, 3]);

      final leftovers = tempDir
          .listSync()
          .where((e) => e.path != path)
          .toList();
      expect(leftovers, isEmpty);
    });

    test(
      'sets the execute bit',
      () async {
        const fs = IoCliFileSystem();
        final path = pathIn(tempDir, 'cx');

        await fs.writeExecutable(path, [1, 2, 3]);

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
          await fs.writeExecutable(path, [1, 2, 3]);
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

        await fs.writeExecutable(path, [1, 2, 3]);

        expect(io.File(path).readAsBytesSync(), [1, 2, 3]);
      },
      skip: io.Platform.isWindows ? false : 'Windows-specific replace path',
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
  });

  group('canonicalize', () {
    test('resolves a symlink to the same canonical path as its target', () {
      final target = pathIn(tempDir, 'real');
      io.File(target).writeAsBytesSync([1]);
      final linkPath = pathIn(tempDir, 'link');

      try {
        io.Link(linkPath).createSync(target);
      } on io.FileSystemException {
        // Creating a symlink can require a privilege this test process does
        // not have (notably on Windows without Developer Mode enabled); the
        // platform rule under test does not apply in that environment.
        return;
      }

      const fs = IoCliFileSystem();
      expect(fs.canonicalize(linkPath), fs.canonicalize(target));
    });

    test('returns the path itself when nothing exists there', () {
      const fs = IoCliFileSystem();
      final missing = pathIn(tempDir, 'does-not-exist');
      expect(fs.canonicalize(missing), missing);
    });
  });
}
