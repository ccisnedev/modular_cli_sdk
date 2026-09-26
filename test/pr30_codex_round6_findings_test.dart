// Codex round 6 on PR #30 found one medium issue and one missing test.
//
// Finding 1 (cli_plugin_host.dart:145, RuntimeCliPluginHost.contributions):
// contributions<T>() returned `(_contributions[id] ?? const []).cast<T>()`,
// a live cast VIEW over the same mutable backing List<Object?> every
// contribute<T> call writes into, not a defensive copy. Two problems follow
// from that:
//
//  * A caller can widen T past whatever the extension point was declared
//    for (host.contributions<Object?>('doctor.checks')) and the cast
//    succeeds immediately, since List.cast only checks element types on
//    read, not on write. Adding through that view (`.add('invalid')`)
//    corrupts the real, correctly-typed backing list with a value nothing
//    declared, and the type error only surfaces later, far from the plugin
//    that caused it, whenever something else iterates the extension point
//    expecting its declared type.
//  * Even reading back with the correctly declared T, the returned view is
//    still backed by the same live list every other plugin's contributions
//    sit in: calling .clear() or .remove() on it silently erases every
//    other plugin's contribution, not just the caller's own.
//
// Fixed by validating the requested T against _extensionPointTypes, exactly
// as contribute<T> already does (the same two CliPluginError codes,
// PLUGIN_EXTENSION_POINT_UNDECLARED and PLUGIN_EXTENSION_POINT_TYPE_MISMATCH),
// and returning List<T>.unmodifiable(...) instead of a live cast view. The
// wrong-type attack above is closed at the read itself: widening to Object?
// no longer reaches a mutable view at all, it throws immediately. The
// clear()/remove() attack is closed by the list itself refusing mutation.
//
// Finding 2 (missing test): a `help` command a plugin registers during
// buildPlugins() must be classified as the CLI's own (developerRoute in
// modular_cli.dart's own _resolveHelpProvenance), not the SDK's built-in
// default, and the built-in default must never be registered on top of it,
// across repeated run() calls. Every existing help-provenance test
// (round 13, round 14) registers its route or shortcut straight on the
// ModularCli instance; none of them go through a plugin's own
// CliPluginHost, which is the path buildPlugins() itself takes and the one
// _resolveHelpProvenance's own doc comment says a plugin-registered help
// counts through ("a `help` a plugin registers counts as the CLI's own").
// Nothing exercised that claim directly.

import 'package:modular_cli_sdk/modular_cli_sdk.dart';
import 'package:test/test.dart';

import 'doubles.dart';

// ── Shared fixtures ─────────────────────────────────────────────────────────

class _FakePlugin implements CliPlugin {
  _FakePlugin({
    required this.id,
    this.requires = const [],
    required this.onSetup,
  });

  final String id;
  final List<String> requires;
  final void Function(CliPluginHost host) onSetup;

  @override
  CliPluginManifest get manifest => CliPluginManifest(
    id: id,
    displayName: id,
    version: '1.0.0',
    hostApiVersion: '^1.0.0',
    requires: requires,
  );

  @override
  void setup(CliPluginHost host) => onSetup(host);
}

class _MarkerInput extends Input {
  @override
  Map<String, dynamic> toJson() => {};
}

class _MarkerOutput extends Output {
  _MarkerOutput(this.marker);

  final String marker;

  @override
  Map<String, dynamic> toJson() => {'marker': marker};

  @override
  int get exitCode => ExitCode.ok;
}

class _MarkerQuery implements Query<_MarkerInput, _MarkerOutput> {
  _MarkerQuery(this.marker);

  final String marker;

  @override
  final _MarkerInput input = _MarkerInput();

  @override
  String? validate() => null;

  @override
  Future<_MarkerOutput> execute() async => _MarkerOutput(marker);
}

Future<({int exitCode, String stdout, String stderr})> _runWith(
  ModularCli cli,
  List<String> args,
) async {
  final out = MemorySink();
  final err = MemorySink();
  final code = await cli.run(args, stdout: out, stderr: err);
  return (exitCode: code, stdout: out.output, stderr: err.output);
}

void main() {
  group(
    'finding 1: contributions<T>() must not hand back a live, mutable, '
    'uncast-checked view of the backing list',
    () {
      test(
        'reading contributions back with a wider type than the extension '
        'point was declared for throws instead of silently handing back a '
        'view that lets a caller corrupt the real list with the wrong type',
        () {
          final cli =
              ModularCli(suggestionDistance: 2, name: 'x', version: '1.0.0')
                ..plugin(
                  _FakePlugin(
                    id: 'owner',
                    onSetup: (host) {
                      host.declareExtensionPoint<String>('checks');
                      host.contribute<String>('checks', 'a real contribution');
                    },
                  ),
                )
                ..plugin(
                  _FakePlugin(
                    id: 'attacker',
                    requires: const ['owner'],
                    onSetup: (host) {
                      expect(
                        () => host.contributions<Object?>('checks'),
                        throwsA(
                          isA<CliPluginError>().having(
                            (e) => e.code,
                            'code',
                            'PLUGIN_EXTENSION_POINT_TYPE_MISMATCH',
                          ),
                        ),
                      );
                    },
                  ),
                );

          cli.buildPlugins();
        },
      );

      test(
        'the list contributions<T>() returns cannot be cleared, added to, '
        'or have an element removed, so one plugin cannot erase or corrupt '
        "what another plugin contributed",
        () {
          final cli =
              ModularCli(suggestionDistance: 2, name: 'x', version: '1.0.0')
                ..plugin(
                  _FakePlugin(
                    id: 'owner',
                    onSetup: (host) {
                      host.declareExtensionPoint<String>('checks');
                      host.contribute<String>('checks', 'first');
                    },
                  ),
                )
                ..plugin(
                  _FakePlugin(
                    id: 'reader',
                    requires: const ['owner'],
                    onSetup: (host) {
                      final view = host.contributions<String>('checks');
                      expect(view, ['first']);
                      expect(() => view.add('injected'), throwsUnsupportedError);
                      expect(() => view.clear(), throwsUnsupportedError);
                      expect(
                        () => view.removeAt(0),
                        throwsUnsupportedError,
                      );
                    },
                  ),
                );

          cli.buildPlugins();
        },
      );

      test(
        'reading contributions for an extension point nothing declared '
        'still fails the same way contribute<T> itself already does',
        () {
          final cli =
              ModularCli(suggestionDistance: 2, name: 'x', version: '1.0.0')
                ..plugin(
                  _FakePlugin(
                    id: 'reader',
                    onSetup: (host) {
                      expect(
                        () => host.contributions<String>('never-declared'),
                        throwsA(
                          isA<CliPluginError>().having(
                            (e) => e.code,
                            'code',
                            'PLUGIN_EXTENSION_POINT_UNDECLARED',
                          ),
                        ),
                      );
                    },
                  ),
                );

          cli.buildPlugins();
        },
      );
    },
  );

  group(
    "finding 2: a help command a plugin registers during buildPlugins() "
    "counts as the CLI's own",
    () {
      ModularCli cliWithAPluginRegisteredHelp() {
        final cli = ModularCli(
          suggestionDistance: 2,
          name: 'x',
          version: '1.0.0',
        );
        cli.plugin(
          _FakePlugin(
            id: 'help-plugin',
            onSetup: (host) => host.registerQuery<_MarkerInput, _MarkerOutput>(
              'help',
              (req) => _MarkerQuery('plugin-help-ran'),
              globals: true,
              contract: CliContract.none,
            ),
          ),
        );
        return cli;
      }

      test(
        "a bare invocation, and an explicit `help`, both dispatch to the "
        "plugin's own help handler, never the SDK's built-in catalog",
        () async {
          final bare = await _runWith(cliWithAPluginRegisteredHelp(), []);
          expect(bare.exitCode, equals(ExitCode.ok));
          expect(bare.stdout, contains('plugin-help-ran'));

          final explicit = await _runWith(cliWithAPluginRegisteredHelp(), [
            'help',
          ]);
          expect(explicit.exitCode, equals(ExitCode.ok));
          expect(explicit.stdout, contains('plugin-help-ran'));
        },
      );

      test(
        "the SDK never registers its own built-in help on top of the "
        "plugin's, across repeated run() calls on the same instance, and "
        "the catalog only ever holds one `help` entry",
        () async {
          final cli = cliWithAPluginRegisteredHelp();

          final first = await _runWith(cli, ['help']);
          final second = await _runWith(cli, ['help']);
          final third = await _runWith(cli, []);

          expect(first.exitCode, equals(ExitCode.ok));
          expect(first.stdout, contains('plugin-help-ran'));
          expect(second.exitCode, equals(ExitCode.ok));
          expect(second.stdout, contains('plugin-help-ran'));
          expect(third.exitCode, equals(ExitCode.ok));
          expect(third.stdout, contains('plugin-help-ran'));

          expect(
            cli.catalog.commands.where((c) => c.name == 'help').length,
            equals(1),
          );
        },
      );
    },
  );
}
