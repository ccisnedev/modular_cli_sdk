/// `VersionPlugin` prints the host's own name and version.
library;

import 'package:modular_cli_sdk/modular_cli_sdk.dart';
import 'package:test/test.dart';

import '../doubles.dart';

void main() {
  test('version reports the name and version given to ModularCli', () async {
    final cli = ModularCli(name: 'demo', version: '1.2.3')..plugin(const VersionPlugin());

    final out = MemorySink();
    final code = await cli.run(['version'], stdout: out);

    expect(code, ExitCode.ok);
    expect(out.output, contains('demo: 1.2.3'));
  });

  test('version --json reports name and version as fields', () async {
    final cli = ModularCli(name: 'demo', version: '1.2.3')..plugin(const VersionPlugin());

    final out = MemorySink();
    await cli.run(['version', '--json'], stdout: out);

    expect(out.output, contains('"name": "demo"'));
    expect(out.output, contains('"version": "1.2.3"'));
  });

  test('registering it without host name/version fails at build time', () {
    final cli = ModularCli()..plugin(const VersionPlugin());
    expect(cli.buildPlugins, throwsStateError);
  });
}
