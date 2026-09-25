import 'dart:io' as io;

/// The filesystem and `PATH` access [InstallationPlugin] needs. Injectable so
/// no test touches a real install path — a test supplies a fake that answers
/// from an in-memory map instead.
abstract class CliFileSystem {
  /// The full path [name] resolves to on `PATH`, the way a shell would find
  /// it — or null when nothing on `PATH` is named [name].
  String? resolveOnPath(String name);

  /// Write [bytes] to [path] as an executable file, replacing whatever was
  /// there. On a platform with an executable bit, this sets it.
  Future<void> writeExecutable(String path, List<int> bytes);

  /// Remove the file at [path].
  Future<void> delete(String path);
}

/// Resolves against the real `PATH` and writes to the real filesystem.
///
/// Used only by production code — a plugin's own tests inject a fake
/// instead, and this class has no test of its own for the same reason
/// `dart:io`-backed code throughout this SDK does not: it has nothing to
/// assert against but the real machine it runs on.
class IoCliFileSystem implements CliFileSystem {
  const IoCliFileSystem();

  @override
  String? resolveOnPath(String name) {
    final pathVar = io.Platform.environment['PATH'];
    if (pathVar == null) return null;

    final isWindows = io.Platform.isWindows;
    final exeName = isWindows && !name.toLowerCase().endsWith('.exe')
        ? '$name.exe'
        : name;

    for (final dir in pathVar.split(isWindows ? ';' : ':')) {
      if (dir.isEmpty) continue;
      final candidate = '$dir${io.Platform.pathSeparator}$exeName';
      if (io.File(candidate).existsSync()) return candidate;
    }
    return null;
  }

  @override
  Future<void> writeExecutable(String path, List<int> bytes) async {
    await io.File(path).writeAsBytes(bytes, flush: true);
    if (!io.Platform.isWindows) {
      await io.Process.run('chmod', ['+x', path]);
    }
  }

  @override
  Future<void> delete(String path) async {
    await io.File(path).delete();
  }
}
