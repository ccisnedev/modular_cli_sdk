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
  ///
  /// [revalidate] is called once the new content has finished staging (the
  /// temporary file written and flushed, and on POSIX chmodded and its
  /// execute bit verified) but immediately before the destructive step that
  /// commits it into place (POSIX: the atomic rename; Windows: moving the
  /// current target aside). A caller uses it to re-check that [path] is
  /// still the target it planned to replace: staging is the slow,
  /// asynchronous part of this call, and re-checking before it rather than
  /// immediately before the commit leaves a window, open for exactly as
  /// long as staging takes, in which the target can change without being
  /// caught. If [revalidate] throws, nothing is committed: the temporary
  /// file is removed and the throw propagates, leaving [path] exactly as it
  /// was.
  Future<void> writeExecutable(
    String path,
    List<int> bytes, {
    required Future<void> Function() revalidate,
  });

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

  /// The canonical, symlink-resolved form of [path].
  ///
  /// Two paths that name the same file on disk by way of a symlink
  /// canonicalize to the same string; comparing paths by this rather than by
  /// their raw string form is how a valid symlinked alias is told apart from
  /// a dangling one. This does *not* catch a hard link: a hard link has no
  /// symlink target to resolve, so two hard-linked paths canonicalize to two
  /// different strings despite naming the same inode. Use [sameFile] where
  /// that also has to be caught.
  ///
  /// A resolution failure (nothing exists at [path], a link in the chain is
  /// dangling, or resolution otherwise fails) must be thrown, not swallowed
  /// into returning [path] itself: a caller resolving an install target
  /// before writing to it relies on that failure surfacing, since silently
  /// falling back to the un-resolved path is how an upgrade ends up
  /// replacing a symlink itself instead of what it points at.
  String canonicalize(String path);

  /// Whether [a] and [b] name the same file on disk, however they got there:
  /// the same raw path, a symlink to the other, or a hard link sharing the
  /// other's inode. This is the strict superset of [canonicalize] equality
  /// that a hard-linked alias needs: [canonicalize] alone reports two
  /// hard-linked paths as different files, since neither is a symlink
  /// pointing at the other.
  bool sameFile(String a, String b);

  /// Whether [path] is a regular file, as opposed to a directory, a symlink
  /// (even one that ultimately points at a regular file), a device, or
  /// nothing at all. Symlinks are deliberately not followed: a caller
  /// revalidating an install target immediately before replacing it needs to
  /// know it is about to write through a plain file, not through whatever a
  /// symlink someone swapped in at the last moment happens to point at.
  bool isRegularFile(String path);
}

/// Thrown when whether a path is executable could not be determined: the
/// fixed platform test executable ([IoCliExecutableChecker]) exited with
/// something other than 0 (executable) or 1 (not executable), could not be
/// started at all, or this platform has no fixed test executable path
/// configured for it. Never folded into a plain true/false: a caller that
/// cannot tell must be told that, not handed a guess.
class CliExecutableCheckFailure implements Exception {
  const CliExecutableCheckFailure(this.path, this.message);

  /// The path the check was for. Empty when the failure is about the
  /// platform itself rather than about a specific path (no fixed test
  /// executable is known for it).
  final String path;

  final String message;

  @override
  String toString() => message;
}

/// Determines whether a path is executable by running the platform's own
/// fixed test executable against it, in place of reading and interpreting
/// mode bits and ownership. Injectable so a test can exercise
/// [IoCliFileSystem.resolveOnPath]'s handling of exit code 0, 1, anything
/// else, and a startup failure, without depending on a real `/bin/test` or
/// `/usr/bin/test`.
abstract class CliExecutableChecker {
  /// The exit code of running the platform's fixed test executable with
  /// `-x` against [path]: conventionally 0 for executable, 1 for not.
  /// Interpreting anything else is the caller's job, not this method's,
  /// except when the checker cannot start at all, which it reports by
  /// throwing rather than returning a made-up code.
  int exitCodeFor(String path);
}

/// Shells out to a fixed, non-searched path per platform: `/bin/test` on
/// macOS, `/usr/bin/test` on Linux. Neither `PATH` search nor any
/// alternative path is tried: a platform this does not have a fixed path
/// for is a configuration gap to report through
/// [CliExecutableCheckFailure], not a guess to make by falling back to
/// mode bits or trying other locations.
class IoCliExecutableChecker implements CliExecutableChecker {
  const IoCliExecutableChecker();

  @override
  int exitCodeFor(String path) {
    final testExecutable = _testExecutablePath(path);
    final io.ProcessResult result;
    try {
      result = io.Process.runSync(testExecutable, ['-x', path]);
    } on Object catch (e) {
      throw CliExecutableCheckFailure(
        path,
        'Could not start $testExecutable to check whether $path is '
            'executable: $e',
      );
    }
    return result.exitCode;
  }

  String _testExecutablePath(String path) {
    if (io.Platform.isMacOS) return '/bin/test';
    if (io.Platform.isLinux) return '/usr/bin/test';
    throw CliExecutableCheckFailure(
      path,
      'No fixed executable-check path is known for platform '
          '"${io.Platform.operatingSystem}".',
    );
  }
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
  ///
  /// [executableChecker] overrides how a POSIX candidate's executability is
  /// determined, in place of the real `/bin/test` or `/usr/bin/test`. A test
  /// uses this to inject exit codes without spawning a real process.
  const IoCliFileSystem({
    List<String>? pathDirectories,
    CliExecutableChecker? executableChecker,
  }) : _pathDirectories = pathDirectories,
       _executableChecker = executableChecker ?? const IoCliExecutableChecker();

  final List<String>? _pathDirectories;
  final CliExecutableChecker _executableChecker;

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
        if (!io.File(candidate).existsSync()) continue;
        if (isWindows || _canExecute(candidate)) {
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

  /// Whether the calling process may execute the file at [path], determined
  /// by asking the platform itself (through [_executableChecker]) rather
  /// than reading and interpreting the file's mode bits and ownership: the
  /// kernel already knows the rule (effective uid/gid, ACLs, anything else a
  /// given POSIX system layers on top), and re-deriving it from `stat` and
  /// `id` output is exactly the kind of guess that goes wrong on a platform
  /// this was not written against.
  ///
  /// Exit code 0 means executable, 1 means not. Anything else, including
  /// the checker failing to start at all, is surfaced as
  /// [CliExecutableCheckFailure] rather than folded into a boolean: a
  /// caller that cannot tell whether [path] is executable must be told
  /// that, not handed a guess.
  bool _canExecute(String path) {
    final int exitCode;
    try {
      exitCode = _executableChecker.exitCodeFor(path);
    } on CliExecutableCheckFailure {
      rethrow;
    } on Object catch (e) {
      throw CliExecutableCheckFailure(
        path,
        'Could not check whether $path is executable: $e',
      );
    }
    switch (exitCode) {
      case 0:
        return true;
      case 1:
        return false;
      default:
        throw CliExecutableCheckFailure(
          path,
          'Checking whether $path is executable exited with unexpected '
              'code $exitCode.',
        );
    }
  }

  @override
  String canonicalize(String path) => io.File(path).resolveSymbolicLinksSync();

  @override
  bool sameFile(String a, String b) {
    if (a == b) return true;
    if (canonicalize(a) == canonicalize(b)) return true;
    // canonicalize only resolves symlinks; two hard-linked paths have no
    // symlink between them to resolve and so canonicalize to two different
    // strings despite sharing the same inode. identicalFiles checks that
    // directly. A failure there (identicalSync can throw, e.g. on a
    // permission error) is let through rather than folded into false: a
    // caller that cannot tell whether the paths are the same file must be
    // told that, not handed a false "different files" that turns a
    // hard-linked alias, or one that could not be checked at all, into
    // "no issue".
    return identicalFiles(a, b);
  }

  /// Whether [a] and [b] name the same inode, per [io.FileSystemEntity]'s
  /// own [io.FileSystemEntity.identicalSync]. Exposed as its own overridable
  /// method purely as a test seam: a subclass in a test can override this to
  /// throw on demand, which is the only way to exercise [sameFile]'s
  /// propagation of an identity-check failure, since nothing in `dart:io`
  /// lets a test provoke an identicalSync failure at this exact point
  /// otherwise. Production code never overrides this.
  bool identicalFiles(String a, String b) =>
      io.FileSystemEntity.identicalSync(a, b);

  @override
  bool isRegularFile(String path) =>
      io.FileSystemEntity.typeSync(path, followLinks: false) ==
      io.FileSystemEntityType.file;

  @override
  Future<void> writeExecutable(
    String path,
    List<int> bytes, {
    required Future<void> Function() revalidate,
  }) async {
    final tempPath =
        '$path.tmp-${io.pid}-${DateTime.now().microsecondsSinceEpoch}';
    final temp = io.File(tempPath);
    await temp.writeAsBytes(bytes, flush: true);

    try {
      if (!io.Platform.isWindows) {
        await io.Process.run('chmod', ['+x', tempPath]);
        // Reuses the same strict interpretation resolveOnPath's own
        // executability check applies: exit code 1 (not executable) is the
        // only outcome chmod is blamed for below. Anything else, including
        // the checker failing to start at all, is a CliExecutableCheckFailure
        // that propagates as itself rather than being folded into the same
        // chmod-blamed error, since a checker that could not answer is not
        // evidence chmod did anything wrong.
        if (!_canExecute(tempPath)) {
          throw io.FileSystemException(
            'chmod +x did not set an execute bit on the downloaded file',
            tempPath,
          );
        }
        // Staging (the write above, plus chmod and its verification) is
        // the slow, asynchronous part of this call: re-checking the target
        // immediately before the commit below, rather than before staging
        // started, is what keeps that window from being one in which the
        // target can change unnoticed.
        await revalidate();
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
      // after the old one has been moved out of the way. Revalidated here,
      // immediately before this first destructive step, for the same
      // reason as the POSIX branch above: staging (the write above) is
      // already done by this point, so this is as close to the commit as
      // the check can run.
      await revalidate();
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
