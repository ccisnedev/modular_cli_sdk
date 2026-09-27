/// `DoctorPlugin` runs whatever checks were contributed to `doctor.checks`
/// and reports them together, exiting non-zero only when one of them errors.
library;

import 'dart:convert';

import 'package:modular_cli_sdk/modular_cli_sdk.dart';
import 'package:test/test.dart';

import '../doubles.dart';

void main() {
  test(
    'with no checks contributed, doctor reports none and exits ok',
    () async {
      final cli = ModularCli(suggestionDistance: 2, name: 'x', version: '1.0.0')
        ..plugin(const DoctorPlugin());

      final code = await cli.run(['doctor'], stdout: MemorySink());
      expect(code, ExitCode.ok);
    },
  );

  test('every check ok exits ok', () async {
    final cli = ModularCli(suggestionDistance: 2, name: 'x', version: '1.0.0')
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
    final cli = ModularCli(suggestionDistance: 2, name: 'x', version: '1.0.0')
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
    final cli = ModularCli(suggestionDistance: 2, name: 'x', version: '1.0.0')
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
      final cli = ModularCli(suggestionDistance: 2, name: 'x', version: '1.0.0')
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

      final out = MemorySink();
      final err = MemorySink();
      final code = await cli.run(['doctor'], stdout: out, stderr: err);

      // A doctor failure is the single error shape, not the success shaped
      // checks array: nothing is written to stdout, the error (naming the
      // failed check) goes to stderr instead.
      expect(code, ExitCode.configError);
      expect(out.output, isEmpty);
      expect(err.output, contains('doctor-check-failed'));
      expect(err.output, contains('alias'));
    },
  );

  test('doctor --json reports every check by name', () async {
    final cli = ModularCli(suggestionDistance: 2, name: 'x', version: '1.0.0')
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
    'doctor --json reports the exact ordered checks array on success',
    () async {
      final cli = ModularCli(suggestionDistance: 2, name: 'x', version: '1.0.0')
        ..plugin(const DoctorPlugin())
        ..plugin(
          _CheckContributingPlugin([
            _constantCheck(
              name: 'binary',
              status: CliCheckStatus.ok,
              message: 'cx found at /usr/local/bin/cx',
            ),
            _constantCheck(
              name: 'release',
              status: CliCheckStatus.warning,
              message: 'a newer release is available',
            ),
          ]),
        );

      final out = MemorySink();
      await cli.run(['doctor', '--json'], stdout: out);

      // The whole array, in check-run order, with nothing extra and nothing
      // missing: a substring `contains` check (as the rest of this file
      // uses) cannot tell an array in the right shape but the wrong order
      // apart from one that happens to contain the same substrings.
      expect(jsonDecode(out.output), {
        'checks': [
          {
            'name': 'binary',
            'status': 'ok',
            'detail': 'cx found at /usr/local/bin/cx',
          },
          {
            'name': 'release',
            'status': 'warning',
            'detail': 'a newer release is available',
          },
        ],
      });
    },
  );

  test(
    'doctor --json reports the single error shape when a check errors, '
    'with the ordered checks array nested under it',
    () async {
      final cli = ModularCli(suggestionDistance: 2, name: 'x', version: '1.0.0')
        ..plugin(const DoctorPlugin())
        ..plugin(
          _CheckContributingPlugin([
            _constantCheck(
              name: 'binary',
              status: CliCheckStatus.ok,
              message: 'cx found at /usr/local/bin/cx',
            ),
            _constantCheck(
              name: 'alias',
              status: CliCheckStatus.error,
              message: 'calculatrix was not found on PATH',
            ),
            _constantCheck(
              name: 'release',
              status: CliCheckStatus.warning,
              message: 'a newer release is available',
            ),
          ]),
        );

      final out = MemorySink();
      final err = MemorySink();
      final code = await cli.run(
        ['doctor', '--json'],
        stdout: out,
        stderr: err,
      );

      // A checks-array failure is never data on stdout: the single error
      // shape carries the whole array under its own "error" key instead.
      expect(code, ExitCode.configError);
      expect(out.output, isEmpty);
      expect(jsonDecode(err.output), {
        'error': {
          'id': 'doctor-check-failed',
          'message': '1 check(s) failed: alias',
          'exitCode': ExitCode.configError,
          'checks': [
            {
              'name': 'binary',
              'status': 'ok',
              'detail': 'cx found at /usr/local/bin/cx',
            },
            {
              'name': 'alias',
              'status': 'error',
              'detail': 'calculatrix was not found on PATH',
            },
            {
              'name': 'release',
              'status': 'warning',
              'detail': 'a newer release is available',
            },
          ],
        },
      });
    },
  );

  test(
    'two checks sharing a name are both kept, in order, rather than one overwriting the other',
    () async {
      final cli = ModularCli(suggestionDistance: 2, name: 'x', version: '1.0.0')
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
      final err = MemorySink();
      final code = await cli.run(
        ['doctor', '--json'],
        stdout: out,
        stderr: err,
      );

      // A later ok must not overwrite an earlier error: the exit code is
      // computed from every result, not just the last one written under a
      // name two checks happen to share, and both results still show up in
      // the failure envelope's own checks array, nothing on stdout.
      expect(code, ExitCode.configError);
      expect(out.output, isEmpty);
      expect(err.output, contains('first, broken'));
      expect(err.output, contains('second, fine'));
    },
  );

  test(
    'a check that throws is recorded as an error and the rest still run',
    () async {
      final cli = ModularCli(suggestionDistance: 2, name: 'x', version: '1.0.0')
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
      final err = MemorySink();
      final code = await cli.run(['doctor'], stdout: out, stderr: err);

      // Text mode: the check lines (including the one that threw, and the
      // ones that ran after it) plus the error line, all on stderr, nothing
      // on stdout.
      expect(code, ExitCode.configError);
      expect(out.output, isEmpty);
      expect(err.output, contains('found'));
      expect(err.output, contains('alias'));
      expect(err.output, contains('boom'));
      expect(err.output, contains('up to date'));
      expect(err.output, contains('doctor-check-failed'));
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
