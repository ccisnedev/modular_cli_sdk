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

  /// Makes [sameFile] throw [sameFileError] on every call, in place of its
  /// normal identity comparison. Used to exercise a caller
  /// (`hardLinkedAliasIssue`, in particular) that must propagate a
  /// [sameFile] resolution failure rather than swallow it.
  Object? sameFileError;

  /// Once [canonicalize] has been called [canonicalizeErrorAfterCalls]
  /// times, every call after that throws [canonicalizeError] instead of
  /// resolving normally; calls up to and including that count still resolve
  /// normally. Left at 0 (the default whenever [canonicalizeError] is set),
  /// every call throws, matching the plain [canonicalizeError] behaviour
  /// this replaces. A test sets this higher to let an earlier caller (e.g.
  /// [sameFile]'s own internal canonicalize calls) succeed, and only a
  /// later, separate canonicalize call fail.
  int canonicalizeErrorAfterCalls = 0;
  int _canonicalizeCalls = 0;

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
    _canonicalizeCalls++;
    if (canonicalizeError != null &&
        _canonicalizeCalls > canonicalizeErrorAfterCalls) {
      throw canonicalizeError!;
    }
    return _canonicalTargets[path] ?? path;
  }

  @override
  bool sameFile(String a, String b) {
    if (sameFileError != null) throw sameFileError!;
    return a == b ||
        canonicalize(a) == canonicalize(b) ||
        _hardLinkedPairs.contains((a, b));
  }

  @override
  bool isRegularFile(String path) => !nonRegularFiles.contains(path);

  @override
  Future<void> writeExecutable(
    String path,
    List<int> bytes, {
    required Future<void> Function() revalidate,
  }) async {
    if (writeError != null) throw writeError!;
    await revalidate();
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

/// Records what would have been launched instead of starting a real cleanup
/// worker, so a test of the Windows self-delete step can assert what it
/// launches without a real PowerShell process and a real second PID.
class FakeProcessLauncher implements CliProcessLauncher {
  FakeProcessLauncher({
    int pid = 4242,
    this.startError,
    this.readyLine = 'READY',
  }) : currentPid = pid;

  @override
  final int currentPid;

  final Object? startError;

  /// The first line the fake worker's stdout would have produced. Left at
  /// the default `'READY'`, [startCleanupWorker] succeeds; set to anything
  /// else (including null, simulating no output at all before the startup
  /// timeout) to exercise the handshake-failure path without a real process
  /// or a real timeout.
  final String? readyLine;

  /// Every payload passed to [startCleanupWorker], in order.
  final List<Map<String, Object?>> startedCleanupWorkers = [];

  @override
  Future<void> startCleanupWorker(Map<String, Object?> payload) async {
    if (startError != null) throw startError!;
    if (readyLine != 'READY') {
      throw CliCleanupWorkerStartFailure(
        'The cleanup worker\'s first line of output was "$readyLine", not '
        'READY.',
      );
    }
    startedCleanupWorkers.add(payload);
  }
}
