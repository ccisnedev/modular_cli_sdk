/// `DoctorPlugin` runs whatever checks were contributed to `doctor.checks`
/// and reports them together, exiting non-zero only when one of them errors.
library;

import 'package:modular_cli_sdk/modular_cli_sdk.dart';
import 'package:test/test.dart';

import '../doubles.dart';

void main() {
  test(
    'with no checks contributed, doctor reports none and exits ok',
    () async {
      final cli = ModularCli(name: 'x', version: '1.0.0')
        ..plugin(const DoctorPlugin());

      final code = await cli.run(['doctor'], stdout: MemorySink());
      expect(code, ExitCode.ok);
    },
  );

  test('every check ok exits ok', () async {
    final cli = ModularCli(name: 'x', version: '1.0.0')
      ..plugin(const DoctorPlugin())
      ..plugin(
        _CheckContributingPlugin([
          _constantCheck(name: 'a', status: CliCheckStatus.ok, message: 'fine'),
        ]),
      );

    final out = MemorySink();
    final code = await cli.run(['doctor'], stdout: out);

    expect(code, ExitCode.ok);
    expect(out.output, contains('fine'));
  });

  test('a warning does not fail doctor', () async {
    final cli = ModularCli(name: 'x', version: '1.0.0')
      ..plugin(const DoctorPlugin())
      ..plugin(
        _CheckContributingPlugin([
          _constantCheck(
            name: 'release',
            status: CliCheckStatus.warning,
            message: 'a newer release is available',
          ),
        ]),
      );

    final out = MemorySink();
    final code = await cli.run(['doctor'], stdout: out);

    expect(code, ExitCode.ok);
    expect(out.output, contains('a newer release is available'));
  });

  test('a lookup failure is reported as a warning, not an error', () async {
    final cli = ModularCli(name: 'x', version: '1.0.0')
      ..plugin(const DoctorPlugin())
      ..plugin(
        _CheckContributingPlugin([
          _constantCheck(
            name: 'release',
            status: CliCheckStatus.warning,
            message: 'could not check for a newer release',
          ),
        ]),
      );

    final code = await cli.run(['doctor'], stdout: MemorySink());
    expect(code, ExitCode.ok);
  });

  test(
    'one error exits configError (78), even alongside ok and warning',
    () async {
      final cli = ModularCli(name: 'x', version: '1.0.0')
        ..plugin(const DoctorPlugin())
        ..plugin(
          _CheckContributingPlugin([
            _constantCheck(
              name: 'binary',
              status: CliCheckStatus.ok,
              message: 'found',
            ),
            _constantCheck(
              name: 'release',
              status: CliCheckStatus.warning,
              message: 'newer available',
            ),
            _constantCheck(
              name: 'alias',
              status: CliCheckStatus.error,
              message: 'missing',
            ),
          ]),
        );

      final code = await cli.run(['doctor'], stdout: MemorySink());
      expect(code, ExitCode.configError);
    },
  );

  test('doctor --json reports every check by name', () async {
    final cli = ModularCli(name: 'x', version: '1.0.0')
      ..plugin(const DoctorPlugin())
      ..plugin(
        _CheckContributingPlugin([
          _constantCheck(
            name: 'binary',
            status: CliCheckStatus.ok,
            message: 'found',
          ),
        ]),
      );

    final out = MemorySink();
    await cli.run(['doctor', '--json'], stdout: out);

    expect(out.output, contains('"binary"'));
    expect(out.output, contains('"status": "ok"'));
  });

  test(
    'two checks sharing a name are both kept, in order, rather than one overwriting the other',
    () async {
      final cli = ModularCli(name: 'x', version: '1.0.0')
        ..plugin(const DoctorPlugin())
        ..plugin(
          _CheckContributingPlugin([
            _constantCheck(
              name: 'release',
              status: CliCheckStatus.error,
              message: 'first, broken',
            ),
            _constantCheck(
              name: 'release',
              status: CliCheckStatus.ok,
              message: 'second, fine',
            ),
          ]),
        );

      final out = MemorySink();
      final code = await cli.run(['doctor', '--json'], stdout: out);

      // A later ok must not overwrite an earlier error: the exit code is
      // computed from every result, not just the last one written under a
      // name two checks happen to share.
      expect(code, ExitCode.configError);
      expect(out.output, contains('first, broken'));
      expect(out.output, contains('second, fine'));
    },
  );

  test(
    'a check that throws is recorded as an error and the rest still run',
    () async {
      final cli = ModularCli(name: 'x', version: '1.0.0')
        ..plugin(const DoctorPlugin())
        ..plugin(
          _CheckContributingPlugin([
            _constantCheck(
              name: 'binary',
              status: CliCheckStatus.ok,
              message: 'found',
            ),
            CliDoctorCheck(
              name: 'alias',
              run: () async => throw StateError('boom'),
            ),
            _constantCheck(
              name: 'release',
              status: CliCheckStatus.ok,
              message: 'up to date',
            ),
          ]),
        );

      final out = MemorySink();
      final code = await cli.run(['doctor'], stdout: out);

      expect(code, ExitCode.configError);
      expect(out.output, contains('found'));
      expect(out.output, contains('alias'));
      expect(out.output, contains('boom'));
      expect(out.output, contains('up to date'));
    },
  );
}

CliDoctorCheck _constantCheck({
  required String name,
  required CliCheckStatus status,
  required String message,
}) => CliDoctorCheck(
  name: name,
  run: () async => CliCheckResult(status: status, message: message),
);

/// A plugin that declares no extension points of its own and contributes a
/// fixed list of [CliDoctorCheck]s to `doctor.checks`: it must therefore
/// [CliPluginManifest.requires] `modular_cli.doctor`, exactly as any real
/// contributor (such as `InstallationPlugin`) does.
class _CheckContributingPlugin implements CliPlugin {
  _CheckContributingPlugin(this.checks);

  final List<CliDoctorCheck> checks;

  @override
  CliPluginManifest get manifest => const CliPluginManifest(
    id: 'test.checks',
    displayName: 'test checks',
    version: '1.0.0',
    hostApiVersion: '^1.0.0',
    requires: ['modular_cli.doctor'],
  );

  @override
  void setup(CliPluginHost host) {
    for (final check in checks) {
      host.contribute<CliDoctorCheck>(DoctorPlugin.extensionPoint, check);
    }
  }
}
