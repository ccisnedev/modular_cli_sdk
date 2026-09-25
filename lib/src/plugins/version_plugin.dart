import '../cli_plugin.dart';
import '../exit_codes.dart';
import '../input.dart';
import '../output.dart';
import '../query.dart';

/// `version` prints the host CLI's own name and version.
///
/// The simplest of the three standard plugins: by default it reads nothing
/// but [CliPluginHost.metadata], so a host that registers a bare
/// `VersionPlugin()` must have been constructed with
/// `ModularCli(name: ..., version: ...)`. [version], when given, is reported
/// in place of [CliHostMetadata.version] (the name still always comes from
/// the host): a plugin that ships as its own versioned unit, distinct from
/// the umbrella CLI's own version, names itself this way rather than by
/// overwriting the host's.
class VersionPlugin implements CliPlugin {
  const VersionPlugin({this.version});

  /// Reported in place of the host's own version when given.
  final String? version;

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
    final reportedVersion = version ?? metadata.version;
    host.registerQuery<VersionInput, VersionOutput>(
      'version',
      (req) => VersionQuery(
        VersionInput(),
        name: metadata.name,
        version: reportedVersion,
      ),
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
