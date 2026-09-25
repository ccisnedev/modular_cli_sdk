/// Doubles for `InstallationPlugin`'s tests: fakes for every interface it
/// takes network, filesystem and platform access through, so no test in this
/// directory downloads anything or touches a real install path.
library;

import 'package:modular_cli_sdk/modular_cli_sdk.dart';

class FakeReleaseSource implements CliReleaseSource {
  FakeReleaseSource({this.releases = const [], this.error});

  final List<CliRelease> releases;
  final Object? error;

  @override
  Future<List<CliRelease>> listReleases(String repository) async {
    if (error != null) throw error!;
    return releases;
  }
}

class FakeDownloader implements CliDownloader {
  FakeDownloader({this.bytes = const [1, 2, 3], this.error, this.onDownload});

  final List<int> bytes;
  final Object? error;

  /// Called at the point a real download would have happened, before
  /// [download] returns. A test uses this to mutate a shared [FakeFileSystem]
  /// (a target's resolved path, its canonical target, whether it is still a
  /// regular file) at exactly the moment between an `--apply` run's own plan
  /// and its own install step, since a single `steps()` invocation gives a
  /// test no other seam to act at that specific point.
  final void Function()? onDownload;

  final List<String> requested = [];

  @override
  Future<List<int>> download(String url) async {
    requested.add(url);
    onDownload?.call();
    if (error != null) throw error!;
    return bytes;
  }
}

/// Resolves names against an in-memory `PATH` map, and records writes/deletes
/// instead of touching disk.
///
/// [canonicalTargets] maps a raw path to the canonical target it stands for,
/// the way a real filesystem's symlink resolution would, so a test can set
/// up two different `PATH` entries (an executable and a symlinked alias)
/// that both resolve to the same file without their raw path strings being
/// equal.
class FakeFileSystem implements CliFileSystem {
  FakeFileSystem({
    Map<String, String>? onPath,
    Map<String, String>? canonicalTargets,
  }) : _onPath = {...?onPath},
       _canonicalTargets = {...?canonicalTargets};

  final Map<String, String> _onPath;
  final Map<String, String> _canonicalTargets;
  final Map<String, List<int>> written = {};
  final List<String> deleted = [];

  /// Every rename this fake performed, as `(from, to)` pairs, in order.
  final List<(String, String)> renamed = [];

  /// Paths this fake reports as not a regular file (a directory, a symlink,
  /// or nothing at all) from [isRegularFile]. Every other path is reported
  /// as a regular file, matching a freshly written install target.
  final Set<String> nonRegularFiles = {};

  /// Pairs this fake reports as [sameFile] true despite canonicalizing to
  /// different strings, the way a hard link (as opposed to a symlink) does:
  /// [sameFile] resolves it, but [canonicalize] alone cannot, since a hard
  /// link has no symlink target for it to follow.
  final Set<(String, String)> _hardLinkedPairs = {};

  Object? writeError;
  Object? deleteError;
  Object? renameError;
  Object? canonicalizeError;
  Object? resolveOnPathError;

  @override
  String? resolveOnPath(String name) {
    if (resolveOnPathError != null) throw resolveOnPathError!;
    return _onPath[name];
  }

  /// Sets what [name] resolves to on the fake `PATH`, or removes it when
  /// [path] is null. Used to simulate a target that disappears from, or
  /// changes on, `PATH` between an `--apply` run's own plan and its own
  /// replace step.
  void setOnPath(String name, String? path) {
    if (path == null) {
      _onPath.remove(name);
    } else {
      _onPath[name] = path;
    }
  }

  /// Sets what [path] canonicalizes to, or removes the override (so it
  /// canonicalizes to itself) when [target] is null. Used to simulate a
  /// `PATH` entry that starts pointing somewhere else between an `--apply`
  /// run's own plan and its own replace step.
  void setCanonicalTarget(String path, String? target) {
    if (target == null) {
      _canonicalTargets.remove(path);
    } else {
      _canonicalTargets[path] = target;
    }
  }

  /// Marks [a] and [b] as a hard-linked pair: [sameFile] reports them as the
  /// same file, but [canonicalize] does not, since a hard link has no
  /// symlink target for [canonicalize] to resolve. Symmetric: it does not
  /// matter which of [a], [b] is passed first.
  void markHardLinked(String a, String b) {
    _hardLinkedPairs.add((a, b));
    _hardLinkedPairs.add((b, a));
  }

  @override
  String canonicalize(String path) {
    if (canonicalizeError != null) throw canonicalizeError!;
    return _canonicalTargets[path] ?? path;
  }

  @override
  bool sameFile(String a, String b) =>
      a == b ||
      canonicalize(a) == canonicalize(b) ||
      _hardLinkedPairs.contains((a, b));

  @override
  bool isRegularFile(String path) => !nonRegularFiles.contains(path);

  @override
  Future<void> writeExecutable(String path, List<int> bytes) async {
    if (writeError != null) throw writeError!;
    written[path] = bytes;
  }

  @override
  Future<void> delete(String path) async {
    if (deleteError != null) throw deleteError!;
    // A real filesystem's second delete of an already-removed path fails;
    // this fake rejects it the same way, so a bug that queues the same
    // entry for removal twice (the alias-and-executable identity bug this
    // fake exists to catch) fails a test instead of passing one by quietly
    // recording the same path twice.
    if (deleted.contains(path)) {
      throw StateError('$path was already deleted');
    }
    deleted.add(path);
    _onPath.removeWhere((name, resolved) => resolved == path);
  }

  @override
  Future<void> rename(String from, String to) async {
    if (renameError != null) throw renameError!;
    renamed.add((from, to));
    // Mirrors [delete]'s own bookkeeping: whatever used to resolve to
    // [from] resolves to [to] afterwards, since that is what a real rename
    // does to anything already looked up on `PATH`.
    _onPath.updateAll((name, resolved) => resolved == from ? to : resolved);
  }
}

class FakePlatform implements CliPlatform {
  const FakePlatform(this.operatingSystem);

  @override
  final String operatingSystem;
}

/// Records what would have been launched instead of starting a real
/// detached process, so a test of the Windows self-delete step can assert
/// what it launches without a real `cmd.exe` and a real second PID.
class FakeProcessLauncher implements CliProcessLauncher {
  FakeProcessLauncher({int pid = 4242, this.startError}) : currentPid = pid;

  @override
  final int currentPid;

  final Object? startError;

  /// Every call to [start], as `(executable, arguments)` pairs, in order.
  final List<(String, List<String>)> started = [];

  @override
  Future<void> start(String executable, List<String> arguments) async {
    if (startError != null) throw startError!;
    started.add((executable, arguments));
  }
}
