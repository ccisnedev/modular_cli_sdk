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
  FakeDownloader({this.bytes = const [1, 2, 3], this.error});

  final List<int> bytes;
  final Object? error;

  final List<String> requested = [];

  @override
  Future<List<int>> download(String url) async {
    requested.add(url);
    if (error != null) throw error!;
    return bytes;
  }
}

/// Resolves names against an in-memory `PATH` map, and records writes/deletes
/// instead of touching disk.
class FakeFileSystem implements CliFileSystem {
  FakeFileSystem({Map<String, String>? onPath}) : _onPath = {...?onPath};

  final Map<String, String> _onPath;
  final Map<String, List<int>> written = {};
  final List<String> deleted = [];

  Object? writeError;
  Object? deleteError;

  @override
  String? resolveOnPath(String name) => _onPath[name];

  @override
  Future<void> writeExecutable(String path, List<int> bytes) async {
    if (writeError != null) throw writeError!;
    written[path] = bytes;
  }

  @override
  Future<void> delete(String path) async {
    if (deleteError != null) throw deleteError!;
    deleted.add(path);
    _onPath.removeWhere((name, resolved) => resolved == path);
  }
}

class FakePlatform implements CliPlatform {
  const FakePlatform(this.operatingSystem);

  @override
  final String operatingSystem;
}
