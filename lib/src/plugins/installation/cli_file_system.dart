import 'dart:io' as io;

/// The filesystem and `PATH` access [InstallationPlugin] needs. Injectable so
/// no test touches a real install path, a test supplies a fake that answers
/// from an in-memory map instead.
abstract class CliFileSystem {
  /// The full path [name] resolves to on `PATH`, the way a shell would find
  /// it, or null when nothing on `PATH` is named [name].
  ///
  /// Only a candidate the platform could actually run is returned: an
  /// earlier `PATH` entry that exists but is not executable (POSIX: missing
  /// every execute bit; Windows: an extension `PATHEXT` does not list) is
  /// skipped in favor of the next candidate, exactly as a shell's own lookup
  /// would skip it.
  String? resolveOnPath(String name);

  /// Write [bytes] to [path] as an executable file, replacing whatever was
  /// there. On a platform with an executable bit, this sets it, and the bit
  /// is verified before the write is allowed to count as having succeeded.
  ///
  /// Safe to call on [path] while it is the currently running executable:
  /// the new content is written to a temporary file beside [path] first,
  /// then put into place the way each platform allows a running executable
  /// to be replaced (POSIX: an atomic rename; Windows: the current target is
  /// moved aside before the new file takes its name), rather than truncating
  /// [path] itself and writing into it in place, which on Linux fails the
  /// running process with `ETXTBSY` and, on a platform where the truncate is
  /// allowed to start, destroys the installation the moment the write after
  /// it fails.
  Future<void> writeExecutable(String path, List<int> bytes);

  /// Remove the file at [path].
  ///
  /// [path] may itself be a symlink: the link entry is removed, not
  /// whatever it points at, and this succeeds even when the link is
  /// dangling (its target no longer exists).
  Future<void> delete(String path);

  /// Renames (moves) the file at [from] to [to], both within the same
  /// filesystem. Used where a file must be moved out of the way rather than
  /// deleted outright, e.g. a running Windows executable that cannot be
  /// deleted but can be renamed.
  Future<void> rename(String from, String to);

  /// The canonical, symlink-resolved form of [path], or [path] itself when
  /// it cannot be resolved (nothing exists there, or resolution fails).
  ///
  /// Two paths that name the same file on disk by way of a symlink
  /// canonicalize to the same string; comparing paths by this rather than by
  /// their raw string form is how a valid symlinked alias is told apart from
  /// a dangling one. This does *not* catch a hard link: a hard link has no
  /// symlink target to resolve, so two hard-linked paths canonicalize to two
  /// different strings despite naming the same inode. Use [sameFile] where
  /// that also has to be caught.
  String canonicalize(String path) => path;

  /// Whether [a] and [b] name the same file on disk, however they got there:
  /// the same raw path, a symlink to the other, or a hard link sharing the
  /// other's inode. This is the strict superset of [canonicalize] equality
  /// that a hard-linked alias needs: [canonicalize] alone reports two
  /// hard-linked paths as different files, since neither is a symlink
  /// pointing at the other.
  bool sameFile(String a, String b);
}

/// Resolves against the real `PATH` and writes to the real filesystem.
///
/// Used by production code. [IoCliFileSystem] does carry its own tests
/// (`test/plugins/installation/io_cli_file_system_test.dart`), unlike most
/// `dart:io`-backed code in this SDK, because the platform rules it
/// implements (execution eligibility on `PATH`, an atomic self-replacing
/// write) are exactly the part a fake filesystem cannot exercise: they are
/// facts about the machine, not decisions this plugin makes.
class IoCliFileSystem implements CliFileSystem {
  /// [pathDirectories] overrides the directories [resolveOnPath] walks, in
  /// place of splitting the real `PATH` environment variable. Dart cannot
  /// mutate the environment of its own running process, so this is what a
  /// test uses to exercise the real walking-and-executable-checking logic
  /// against a temporary directory without spawning a subprocess.
  const IoCliFileSystem({List<String>? pathDirectories})
    : _pathDirectories = pathDirectories;

  final List<String>? _pathDirectories;

  List<String> get _directories {
    final override = _pathDirectories;
    if (override != null) return override;
    final pathVar = io.Platform.environment['PATH'];
    if (pathVar == null) return const [];
    return pathVar.split(io.Platform.isWindows ? ';' : ':');
  }

  @override
  String? resolveOnPath(String name) {
    final isWindows = io.Platform.isWindows;
    final candidateNames = isWindows ? _windowsCandidateNames(name) : [name];

    for (final dir in _directories) {
      if (dir.isEmpty) continue;
      for (final candidateName in candidateNames) {
        final candidate = '$dir${io.Platform.pathSeparator}$candidateName';
        final file = io.File(candidate);
        if (!file.existsSync()) continue;
        if (isWindows || _canExecute(candidate, file.statSync().mode)) {
          return candidate;
        }
      }
    }
    return null;
  }

  /// The name(s) to look for in one `PATH` directory on Windows, most
  /// preferred first, following `PATHEXT` (falling back to a fixed default
  /// list when it is unset, as `cmd.exe` itself does). [name] is tried
  /// as-is, with no extension appended, only when it already ends with one
  /// of those extensions.
  List<String> _windowsCandidateNames(String name) {
    final pathExt = io.Platform.environment['PATHEXT'];
    final extensions = (pathExt == null || pathExt.isEmpty)
        ? const ['.EXE', '.CMD', '.BAT', '.COM']
        : pathExt.split(';').where((ext) => ext.isNotEmpty).toList();

    final lower = name.toLowerCase();
    final alreadyHasExtension = extensions.any(
      (ext) => lower.endsWith(ext.toLowerCase()),
    );
    if (alreadyHasExtension) return [name];

    return [for (final ext in extensions) '$name$ext'];
  }

  /// Owner, group, or other execute bit: `0o111`. Used as a permissive
  /// fallback by [_canExecute] when ownership cannot be determined, and by
  /// [writeExecutable] to verify a `chmod +x` it just ran itself (where the
  /// calling user is, by construction, the file's own owner, so "any
  /// execute bit" and "the owner's execute bit" agree).
  bool _hasExecuteBit(int mode) => (mode & 0x49) != 0;

  /// Whether the calling process may execute the file at [path], given its
  /// already-read [mode]. Checks the one bit that actually governs this
  /// process, the way the kernel does: the owner bit when this process's uid
  /// owns [path], the group bit when one of this process's gids matches
  /// [path]'s gid, otherwise the other bit. "Any execute bit is set" (the
  /// previous check) is wrong here: mode `0641` (owner `rw-`, group `r--`,
  /// other `--x`) has an execute bit set, but the file's own owner cannot
  /// run it.
  ///
  /// Falls back to [_hasExecuteBit] when ownership cannot be determined at
  /// all (no working `stat` on this platform), rather than reporting every
  /// file as non-executable.
  bool _canExecute(String path, int mode) {
    final owner = _ownerOf(path);
    if (owner == null) return _hasExecuteBit(mode);
    final (uid, gid) = owner;

    final currentUid = _currentUid();
    if (currentUid != null && currentUid == uid) {
      return (mode & 0x40) != 0; // owner: 0o100
    }
    final currentGids = _currentGids();
    if (currentGids != null && currentGids.contains(gid)) {
      return (mode & 0x08) != 0; // group: 0o010
    }
    return (mode & 0x01) != 0; // other: 0o001
  }

  int? _currentUid() {
    try {
      final result = io.Process.runSync('id', const ['-u']);
      if (result.exitCode != 0) return null;
      return int.tryParse((result.stdout as String).trim());
    } on Object {
      return null;
    }
  }

  Set<int>? _currentGids() {
    try {
      final result = io.Process.runSync('id', const ['-G']);
      if (result.exitCode != 0) return null;
      return (result.stdout as String)
          .trim()
          .split(RegExp(r'\s+'))
          .map(int.tryParse)
          .whereType<int>()
          .toSet();
    } on Object {
      return null;
    }
  }

  /// The owning `(uid, gid)` of the file at [path], or null when it cannot
  /// be determined. Tries GNU coreutils' `stat -c`, then BSD/macOS's
  /// `stat -f`, since [IoCliFileSystem] itself does not know which `stat`
  /// this machine has.
  (int, int)? _ownerOf(String path) {
    for (final args in [
      ['-c', '%u:%g', path],
      ['-f', '%u:%g', path],
    ]) {
      try {
        final result = io.Process.runSync('stat', args);
        if (result.exitCode != 0) continue;
        final parts = (result.stdout as String).trim().split(':');
        if (parts.length != 2) continue;
        final uid = int.tryParse(parts[0]);
        final gid = int.tryParse(parts[1]);
        if (uid != null && gid != null) return (uid, gid);
      } on Object {
        continue;
      }
    }
    return null;
  }

  @override
  String canonicalize(String path) {
    try {
      return io.File(path).resolveSymbolicLinksSync();
    } on io.FileSystemException {
      return path;
    }
  }

  @override
  bool sameFile(String a, String b) {
    if (a == b) return true;
    if (canonicalize(a) == canonicalize(b)) return true;
    // canonicalize only resolves symlinks; two hard-linked paths have no
    // symlink between them to resolve and so canonicalize to two different
    // strings despite sharing the same inode. identicalSync checks that
    // directly.
    try {
      return io.FileSystemEntity.identicalSync(a, b);
    } on io.FileSystemException {
      return false;
    }
  }

  @override
  Future<void> writeExecutable(String path, List<int> bytes) async {
    final tempPath =
        '$path.tmp-${io.pid}-${DateTime.now().microsecondsSinceEpoch}';
    final temp = io.File(tempPath);
    await temp.writeAsBytes(bytes, flush: true);

    try {
      if (!io.Platform.isWindows) {
        await io.Process.run('chmod', ['+x', tempPath]);
        if (!_hasExecuteBit(temp.statSync().mode)) {
          throw io.FileSystemException(
            'chmod +x did not set an execute bit on the downloaded file',
            tempPath,
          );
        }
        // rename(2) is atomic and, on POSIX, replaces the destination even
        // while another process (this one, mid self-upgrade) has it open
        // or mapped for execution: existing handles keep the old inode
        // valid, so this never hits the ETXTBSY a
        // truncate-then-write-in-place would, and never leaves a
        // half-written file at [path] either.
        await temp.rename(path);
        return;
      }

      // The Windows loader has kept a running executable's directory entry
      // free to move since Vista (FILE_SHARE_DELETE), so the exe currently
      // executing can be renamed aside; it cannot be overwritten in place
      // while mapped, which is why the new file only takes [path]'s name
      // after the old one has been moved out of the way.
      final destination = io.File(path);
      String? backupPath;
      if (destination.existsSync()) {
        backupPath =
            '$path.old-${io.pid}-${DateTime.now().microsecondsSinceEpoch}';
        await destination.rename(backupPath);
      }

      try {
        // A separate, overridable step (not inlined) so a test can make
        // exactly this rename fail without a second process actually
        // holding [path] open: the backup must still exist, restorable,
        // when it does.
        await renameIntoPlace(temp, path);
      } on Object {
        // The rename into place failed. [path] no longer exists (moved to
        // [backupPath] above), so the previous installation is restored
        // from the backup before the original failure is let through:
        // deleting the backup up front, as this used to, would otherwise
        // leave the installation gone on a failed upgrade rather than
        // merely not-yet-upgraded.
        if (backupPath != null) {
          try {
            await io.File(backupPath).rename(path);
          } on Object {
            // Best effort: the original failure below is still what the
            // caller needs to see, even if the restore itself fails too.
          }
        }
        rethrow;
      }

      if (backupPath != null) {
        try {
          await io.File(backupPath).delete();
        } on Object {
          // Best effort: the process that was running the old exe can
          // still have it mapped, and that is not a reason to fail an
          // upgrade that has already succeeded.
        }
      }
    } on Object {
      if (temp.existsSync()) {
        try {
          await temp.delete();
        } on Object {
          // Best effort: the original failure is what matters to the
          // caller.
        }
      }
      rethrow;
    }
  }

  /// Renames [temp] to [path] as the last step of a Windows self-replacing
  /// write. Exposed as its own overridable method purely as a test seam: a
  /// subclass in a test can override this to throw on demand, which is the
  /// only way to exercise [writeExecutable]'s Windows failure-and-restore
  /// path, since nothing in `dart:io` lets a test provoke a rename failure
  /// at this exact point otherwise. Production code never overrides this.
  Future<void> renameIntoPlace(io.File temp, String path) async {
    await temp.rename(path);
  }

  @override
  Future<void> delete(String path) async {
    // A symlink is deleted as itself, not through a stat of whatever it
    // points at: File.delete's own implementation resolves the path first,
    // which fails on a dangling symlink (one whose target no longer exists)
    // even though removing the link entry itself has nothing to do with
    // whether its target exists.
    final type = io.FileSystemEntity.typeSync(path, followLinks: false);
    if (type == io.FileSystemEntityType.link) {
      await io.Link(path).delete();
    } else {
      await io.File(path).delete();
    }
  }

  @override
  Future<void> rename(String from, String to) async {
    await io.File(from).rename(to);
  }
}
