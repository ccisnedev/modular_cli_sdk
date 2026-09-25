import '../cli_plugin.dart';
import '../exit_codes.dart';
import '../input.dart';
import '../output.dart';
import '../query.dart';

/// `version` prints the host CLI's own name and version.
///
/// The simplest of the three standard plugins: it reads
/// [CliPluginHost.metadata] and nothing else. A host that registers it must
/// have been constructed with `ModularCli(name: ..., version: ...)`.
class VersionPlugin implements CliPlugin {
  const VersionPlugin();

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
    host.registerQuery<VersionInput, VersionOutput>(
      'version',
      (req) => VersionQuery(VersionInput(), metadata),
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
  VersionQuery(this.input, this.metadata);

  @override
  final VersionInput input;

  final CliHostMetadata metadata;

  @override
  String? validate() => null;

  @override
  Future<VersionOutput> execute() async =>
      VersionOutput(name: metadata.name, version: metadata.version);
}
