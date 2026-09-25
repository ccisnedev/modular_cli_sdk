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
  Future<void> delete(String path);

  /// The canonical, symlink-resolved form of [path], or [path] itself when
  /// it cannot be resolved (nothing exists there, or resolution fails).
  ///
  /// Two paths that name the same file on disk, however they got there (a
  /// symlink, a hard link, redundant `.` segments), canonicalize to the same
  /// string; comparing paths by this rather than by their raw string form is
  /// how a valid symlinked alias is told apart from a dangling one.
  String canonicalize(String path) => path;
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
        if (isWindows || _hasExecuteBit(file.statSync().mode)) {
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

  /// Owner, group, or other execute bit: `0o111`.
  bool _hasExecuteBit(int mode) => (mode & 0x49) != 0;

  @override
  String canonicalize(String path) {
    try {
      return io.File(path).resolveSymbolicLinksSync();
    } on io.FileSystemException {
      return path;
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
      if (destination.existsSync()) {
        final backupPath =
            '$path.old-${io.pid}-${DateTime.now().microsecondsSinceEpoch}';
        await destination.rename(backupPath);
        try {
          await io.File(backupPath).delete();
        } on Object {
          // Best effort: the process that was running the old exe can
          // still have it mapped, and that is not a reason to fail an
          // upgrade that has already succeeded.
        }
      }
      await temp.rename(path);
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

  @override
  Future<void> delete(String path) async {
    await io.File(path).delete();
  }
}
