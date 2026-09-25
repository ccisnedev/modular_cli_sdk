/// Build-time rules for assembling a plugin set: identity, dependency order,
/// host API compatibility, extension points and route collisions.
library;

import 'package:modular_cli_sdk/modular_cli_sdk.dart';
import 'package:test/test.dart';

import '../doubles.dart';

void main() {
  group('build-time failures', () {
    test('two plugins sharing an id', () {
      final cli = ModularCli(name: 'x', version: '1.0.0')
        ..plugin(_FakePlugin(id: 'a'))
        ..plugin(_FakePlugin(id: 'a'));

      expect(
        cli.buildPlugins,
        throwsA(
          isA<CliPluginError>()
              .having((e) => e.code, 'code', 'PLUGIN_DUPLICATE_ID')
              .having((e) => e.pluginId, 'pluginId', 'a'),
        ),
      );
    });

    test('a plugin requiring an id nobody registered', () {
      final cli = ModularCli(name: 'x', version: '1.0.0')
        ..plugin(_FakePlugin(id: 'a', requires: const ['missing']));

      expect(
        cli.buildPlugins,
        throwsA(
          isA<CliPluginError>()
              .having((e) => e.code, 'code', 'PLUGIN_DEPENDENCY_MISSING')
              .having((e) => e.resourceId, 'resourceId', 'missing'),
        ),
      );
    });

    test('a dependency cycle', () {
      final cli = ModularCli(name: 'x', version: '1.0.0')
        ..plugin(_FakePlugin(id: 'a', requires: const ['b']))
        ..plugin(_FakePlugin(id: 'b', requires: const ['a']));

      expect(
        cli.buildPlugins,
        throwsA(
          isA<CliPluginError>().having(
            (e) => e.code,
            'code',
            'PLUGIN_DEPENDENCY_CYCLE',
          ),
        ),
      );
    });

    test('an incompatible hostApiVersion', () {
      final cli = ModularCli(name: 'x', version: '1.0.0')
        ..plugin(_FakePlugin(id: 'a', hostApiVersion: '^99.0.0'));

      expect(
        cli.buildPlugins,
        throwsA(
          isA<CliPluginError>().having(
            (e) => e.code,
            'code',
            'PLUGIN_INCOMPATIBLE_HOST_API',
          ),
        ),
      );
    });

    test('an unparseable hostApiVersion', () {
      final cli = ModularCli(name: 'x', version: '1.0.0')
        ..plugin(_FakePlugin(id: 'a', hostApiVersion: 'not a constraint'));

      expect(
        cli.buildPlugins,
        throwsA(
          isA<CliPluginError>().having(
            (e) => e.code,
            'code',
            'PLUGIN_INCOMPATIBLE_HOST_API',
          ),
        ),
      );
    });

    test('a route two plugins both register', () {
      final cli = ModularCli(name: 'x', version: '1.0.0')
        ..plugin(_FakePlugin(id: 'a', onSetup: _registerCountQuery('shared')))
        ..plugin(_FakePlugin(id: 'b', onSetup: _registerCountQuery('shared')));

      expect(
        cli.buildPlugins,
        throwsA(
          isA<CliPluginError>().having(
            (e) => e.code,
            'code',
            'PLUGIN_DUPLICATE_ROUTE',
          ),
        ),
      );
    });

    test('a contribution to an extension point nobody declared', () {
      final cli = ModularCli(name: 'x', version: '1.0.0')
        ..plugin(
          _FakePlugin(
            id: 'a',
            onSetup: (host) =>
                host.contribute<String>('nobody.declared', 'value'),
          ),
        );

      expect(
        cli.buildPlugins,
        throwsA(
          isA<CliPluginError>().having(
            (e) => e.code,
            'code',
            'PLUGIN_EXTENSION_POINT_UNDECLARED',
          ),
        ),
      );
    });

    test(
      'an extension point declared a second time, with a different type',
      () {
        final cli = ModularCli(name: 'x', version: '1.0.0')
          ..plugin(
            _FakePlugin(
              id: 'a',
              onSetup: (host) {
                host.declareExtensionPoint<String>('p');
                host.declareExtensionPoint<int>('p');
              },
            ),
          );

        expect(
          cli.buildPlugins,
          throwsA(
            isA<CliPluginError>().having(
              (e) => e.code,
              'code',
              'PLUGIN_EXTENSION_POINT_DUPLICATE',
            ),
          ),
        );
      },
    );

    test(
      'an extension point declared a second time, with the same type, is still rejected',
      () {
        final cli = ModularCli(name: 'x', version: '1.0.0')
          ..plugin(
            _FakePlugin(
              id: 'a',
              onSetup: (host) {
                host.declareExtensionPoint<String>('p');
                host.declareExtensionPoint<String>('p');
              },
            ),
          );

        expect(
          cli.buildPlugins,
          throwsA(
            isA<CliPluginError>().having(
              (e) => e.code,
              'code',
              'PLUGIN_EXTENSION_POINT_DUPLICATE',
            ),
          ),
        );
      },
    );

    test('a contribution of the wrong type', () {
      final cli = ModularCli(name: 'x', version: '1.0.0')
        ..plugin(
          _FakePlugin(
            id: 'a',
            onSetup: (host) {
              host.declareExtensionPoint<int>('numbers');
              host.contribute<String>('numbers', 'not a number');
            },
          ),
        );

      expect(
        cli.buildPlugins,
        throwsA(
          isA<CliPluginError>().having(
            (e) => e.code,
            'code',
            'PLUGIN_EXTENSION_POINT_TYPE_MISMATCH',
          ),
        ),
      );
    });

    test('no plugin registered ever runs when one fails validation', () {
      final log = <String>[];
      final cli = ModularCli(name: 'x', version: '1.0.0')
        ..plugin(_FakePlugin(id: 'a', log: log))
        ..plugin(_FakePlugin(id: 'b', requires: const ['missing'], log: log));

      expect(cli.buildPlugins, throwsA(isA<CliPluginError>()));
      expect(log, isEmpty);
    });
  });

  group('extension points and contributions', () {
    test('a declared point with no contribution reads back empty', () {
      final cli = ModularCli(name: 'x', version: '1.0.0')
        ..plugin(
          _FakePlugin(
            id: 'a',
            onSetup: (host) => host.declareExtensionPoint<String>('p'),
          ),
        );

      cli.buildPlugins();
    });

    test('contributions are read back in setup order', () {
      final contributions = <String>[];
      final cli = ModularCli(name: 'x', version: '1.0.0')
        ..plugin(
          _FakePlugin(
            id: 'owner',
            onSetup: (host) => host.declareExtensionPoint<String>('p'),
          ),
        )
        ..plugin(
          _FakePlugin(
            id: 'first',
            requires: const ['owner'],
            onSetup: (host) => host.contribute<String>('p', 'first'),
          ),
        )
        ..plugin(
          _FakePlugin(
            id: 'second',
            requires: const ['owner'],
            onSetup: (host) {
              host.contribute<String>('p', 'second');
              contributions.addAll(host.contributions<String>('p'));
            },
          ),
        );

      cli.buildPlugins();
      expect(contributions, ['first', 'second']);
    });
  });

  group('ordering', () {
    test('a dependency is set up before whatever requires it', () {
      final log = <String>[];
      final cli = ModularCli(name: 'x', version: '1.0.0')
        ..plugin(_FakePlugin(id: 'a', requires: const ['b'], log: log))
        ..plugin(_FakePlugin(id: 'b', log: log));

      cli.buildPlugins();
      expect(log, ['b', 'a']);
    });

    test('registration order is preserved among independent plugins', () {
      final log = <String>[];
      final cli = ModularCli(name: 'x', version: '1.0.0')
        ..plugin(_FakePlugin(id: 'a', log: log))
        ..plugin(_FakePlugin(id: 'b', log: log))
        ..plugin(_FakePlugin(id: 'c', log: log));

      cli.buildPlugins();
      expect(log, ['a', 'b', 'c']);
    });

    test('a transitive dependency still comes first', () {
      final log = <String>[];
      final cli = ModularCli(name: 'x', version: '1.0.0')
        ..plugin(_FakePlugin(id: 'a', requires: const ['b'], log: log))
        ..plugin(_FakePlugin(id: 'b', requires: const ['c'], log: log))
        ..plugin(_FakePlugin(id: 'c', log: log));

      cli.buildPlugins();
      expect(log, ['c', 'b', 'a']);
    });

    test(
      'the sort is stable: registration order breaks ties among a plugin\'s own requirements',
      () {
        final log = <String>[];
        final cli = ModularCli(name: 'x', version: '1.0.0')
          ..plugin(_FakePlugin(id: 'a', requires: const ['c', 'b'], log: log))
          ..plugin(_FakePlugin(id: 'b', log: log))
          ..plugin(_FakePlugin(id: 'c', log: log));

        cli.buildPlugins();
        // a.requires lists c before b, but b was registered before c: setup
        // still runs in registration order among a's requirements, not in the
        // order a happened to list them.
        expect(log, ['b', 'c', 'a']);
      },
    );

    test(
      'Kahn\'s algorithm always picks the earliest-registered eligible '
      'plugin over the whole remaining set, not just a\'s own requirements',
      () {
        final log = <String>[];
        final cli = ModularCli(name: 'x', version: '1.0.0')
          ..plugin(_FakePlugin(id: 'a', requires: const ['c'], log: log))
          ..plugin(_FakePlugin(id: 'b', log: log))
          ..plugin(_FakePlugin(id: 'c', log: log));

        cli.buildPlugins();
        // b does not depend on anything and was registered before c, so it
        // is eligible from the start and must come out before c, even
        // though c is what unblocks a. A depth-first visit in registration
        // order gets this wrong: visiting a first pulls in c (a's own
        // requirement) ahead of b, producing [c, a, b] instead.
        expect(log, ['b', 'c', 'a']);
      },
    );
  });

  group('buildPlugins', () {
    test('is idempotent', () {
      final log = <String>[];
      final cli = ModularCli(name: 'x', version: '1.0.0')
        ..plugin(_FakePlugin(id: 'a', log: log));

      cli.buildPlugins();
      cli.buildPlugins();
      expect(log, ['a']);
    });

    test('run() builds the plugin set before dispatching', () async {
      final log = <String>[];
      final cli = ModularCli(name: 'x', version: '1.0.0')
        ..plugin(_FakePlugin(id: 'a', log: log));

      await cli.run(['help'], stdout: MemorySink(), stderr: MemorySink());
      expect(log, ['a']);
    });

    test('a plugin route is reachable through run()', () async {
      final cli = ModularCli(name: 'x', version: '1.0.0')
        ..plugin(_FakePlugin(id: 'a', onSetup: _registerCountQuery('count')));

      final out = MemorySink();
      final code = await cli.run(['count'], stdout: out);

      expect(code, ExitCode.ok);
      expect(out.output, contains('count: 0'));
    });

    test(
      'a second call after a failed build rethrows the same failure instead of retrying',
      () {
        final cli = ModularCli(name: 'x', version: '1.0.0')
          ..plugin(_FakePlugin(id: 'a', requires: const ['missing']));

        final first = _capture(cli.buildPlugins);
        final second = _capture(cli.buildPlugins);

        expect(first, isA<CliPluginError>());
        expect(second, isA<CliPluginError>());
        expect((second as CliPluginError).code, (first as CliPluginError).code);
      },
    );

    test('a second call after a failed build does not run setup again', () {
      final log = <String>[];
      final cli = ModularCli(name: 'x', version: '1.0.0')
        ..plugin(_FakePlugin(id: 'a', log: log))
        ..plugin(_FakePlugin(id: 'b', requires: const ['missing'], log: log));

      _capture(cli.buildPlugins);
      _capture(cli.buildPlugins);
      // Validation fails before any plugin's setup runs, on both attempts.
      expect(log, isEmpty);
    });

    test('plugin() after a failed build throws StateError', () {
      final cli = ModularCli(name: 'x', version: '1.0.0')
        ..plugin(_FakePlugin(id: 'a', requires: const ['missing']));

      _capture(cli.buildPlugins);
      expect(() => cli.plugin(_FakePlugin(id: 'b')), throwsStateError);
    });

    test('plugin() after a successful build throws StateError', () {
      final cli = ModularCli(name: 'x', version: '1.0.0')
        ..plugin(_FakePlugin(id: 'a'));

      cli.buildPlugins();
      expect(() => cli.plugin(_FakePlugin(id: 'b')), throwsStateError);
    });
  });

  group('host metadata', () {
    test('a plugin reading metadata without name/version fails', () {
      final cli = ModularCli()
        ..plugin(_FakePlugin(id: 'a', onSetup: (host) => host.metadata()));

      expect(cli.buildPlugins, throwsStateError);
    });

    test('a plugin reads the name and version the host declared', () {
      CliHostMetadata? seen;
      final cli = ModularCli(name: 'demo', version: '2.3.4')
        ..plugin(
          _FakePlugin(id: 'a', onSetup: (host) => seen = host.metadata()),
        );

      cli.buildPlugins();
      expect(seen?.name, 'demo');
      expect(seen?.version, '2.3.4');
    });
  });
}

void Function(CliPluginHost) _registerCountQuery(String route) => (host) {
  host.registerQuery<CountInput, CountOutput>(
    route,
    (req) => CountQuery(CountInput(0)),
  );
};

/// Runs [body] and returns whatever it threw, so two failed calls can be
/// compared to each other rather than merely both being "a throw".
Object _capture(void Function() body) {
  try {
    body();
  } on Object catch (e) {
    return e;
  }
  throw StateError('expected $body to throw');
}

/// A plugin whose manifest and behaviour are entirely parameterised, so one
/// class covers every build-time scenario above without a bespoke plugin per
/// test.
class _FakePlugin implements CliPlugin {
  _FakePlugin({
    required this.id,
    this.requires = const [],
    this.hostApiVersion = '^1.0.0',
    List<String>? log,
    void Function(CliPluginHost)? onSetup,
  }) : _log = log,
       _onSetup = onSetup;

  final String id;
  final List<String> requires;
  final String hostApiVersion;
  final List<String>? _log;
  final void Function(CliPluginHost)? _onSetup;

  @override
  CliPluginManifest get manifest => CliPluginManifest(
    id: id,
    displayName: id,
    version: '1.0.0',
    hostApiVersion: hostApiVersion,
    requires: requires,
  );

  @override
  void setup(CliPluginHost host) {
    _log?.add(id);
    _onSetup?.call(host);
  }
}
