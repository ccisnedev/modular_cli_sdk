import '../cli_plugin.dart';
import '../exit_codes.dart';
import '../input.dart';
import '../output.dart';
import '../query.dart';

/// `version` prints the host CLI's own name and version.
///
/// [version] is the CLI's version, and is required: a CLI's version has
/// exactly one source, this one, never a silent fallback to whatever
/// `ModularCli(version: ...)` happened to be given. When both are given and
/// disagree, that is a build-time contradiction, not something [setup]
/// resolves by picking one: it fails with [CliPluginError]
/// (`PLUGIN_VERSION_MISMATCH`), naming both versions, so the two are kept in
/// sync deliberately rather than by one silently winning. The host must
/// still have been constructed with `ModularCli(name: ..., version: ...)`
/// for its name (and, when checked, its version) to exist at all.
class VersionPlugin implements CliPlugin {
  const VersionPlugin({required this.version});

  /// This CLI's version, reported by `version`, `doctor`, and `upgrade`.
  final String version;

  @override
  CliPluginManifest get manifest => const CliPluginManifest(
    id: 'modular_cli.version',
    displayName: 'Version',
    version: '1.0.0',
    hostApiVersion: '^$cliPluginHostApiVersion',
  );

  @override
  void setup(CliPluginHost host) {
    // Read once, at setup: a CLI missing a name/version fails while its
    // plugin set is being built, not on the first person who runs `version`.
    final metadata = host.metadata();
    if (metadata.version != version) {
      throw CliPluginError(
        'PLUGIN_VERSION_MISMATCH',
        'VersionPlugin was given version "$version", but ModularCli was '
            'given version "${metadata.version}". A CLI has exactly one '
            'version: give the same one to both, or only to whichever one '
            'is authoritative.',
        pluginId: manifest.id,
      );
    }
    host.registerQuery<VersionInput, VersionOutput>(
      'version',
      (req) =>
          VersionQuery(VersionInput(), name: metadata.name, version: version),
      globals: true,
      description: "Print this CLI's name and version",
    );
  }
}

class VersionInput extends Input {
  VersionInput();

  @override
  Map<String, dynamic> toJson() => const {};
}

class VersionOutput extends Output {
  VersionOutput({required this.name, required this.version});

  final String name;
  final String version;

  @override
  Map<String, dynamic> toJson() => {'name': name, 'version': version};

  @override
  String? toText() => '$name: $version';

  @override
  int get exitCode => ExitCode.ok;
}

class VersionQuery implements Query<VersionInput, VersionOutput> {
  VersionQuery(this.input, {required this.name, required this.version});

  @override
  final VersionInput input;

  final String name;
  final String version;

  @override
  String? validate() => null;

  @override
  Future<VersionOutput> execute() async =>
      VersionOutput(name: name, version: version);
}
