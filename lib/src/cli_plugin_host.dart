import 'package:cli_router/cli_router.dart';

import 'cli_contract.dart';
import 'cli_plugin.dart';
import 'command.dart';
import 'input.dart';
import 'modular_cli.dart';
import 'output.dart';
import 'query.dart';

/// The [CliPluginHost] a running [ModularCli] hands to each plugin's
/// [CliPlugin.setup], in the order [orderCliPlugins] produced.
///
/// One instance is built per [ModularCli.buildPlugins] call and shared across
/// every plugin in that build, so an extension point declared by one plugin
/// is visible to every plugin set up after it, which dependency order
/// guarantees is every plugin allowed to contribute to it.
class RuntimeCliPluginHost implements CliPluginHost {
  RuntimeCliPluginHost(this._cli);

  final ModularCli _cli;

  /// Registered ids and the type each was declared with.
  final Map<String, Type> _extensionPointTypes = {};
  final Map<String, List<Object?>> _contributions = {};

  /// The plugin currently being set up, set by [ModularCli.buildPlugins]
  /// before each [CliPlugin.setup] call, so a failure inside this host can
  /// name the plugin responsible without that plugin having to repeat its own
  /// id on every call.
  String? currentPluginId;

  @override
  CliHostMetadata metadata() {
    final metadata = _cli.hostMetadata;
    if (metadata == null) {
      throw StateError(
        'No host metadata: construct ModularCli(name: ..., version: ...) '
        'before registering a plugin that calls CliPluginHost.metadata().',
      );
    }
    return metadata;
  }

  @override
  void registerQuery<I extends Input, O extends Output>(
    String route,
    Query<I, O> Function(CliRequest req) queryFactory, {
    String? description,
    required bool globals,
    CliContract contract = CliContract.none,
  }) {
    _guardingDuplicateRoute(
      route,
      () => _cli.query<I, O>(
        route,
        queryFactory,
        globals: globals,
        description: description,
        contract: contract,
      ),
    );
  }

  @override
  void registerCommand<I extends Input, O extends Output>(
    String route,
    Command<I, O> Function(CliRequest req) commandFactory, {
    String? description,
    required bool globals,
    CliContract contract = CliContract.none,
  }) {
    _guardingDuplicateRoute(
      route,
      () => _cli.command<I, O>(
        route,
        commandFactory,
        globals: globals,
        description: description,
        contract: contract,
      ),
    );
  }

  /// `cli_router`'s own trie rejects a route already registered at its
  /// position with a [StateError], caught here and re-thrown as the same
  /// [CliPluginError] vocabulary every other build-time plugin failure uses,
  /// naming the plugin that collided rather than the trie internals that
  /// noticed.
  void _guardingDuplicateRoute(String route, void Function() register) {
    try {
      register();
    } on StateError catch (e) {
      throw CliPluginError(
        'PLUGIN_DUPLICATE_ROUTE',
        'Plugin "${currentPluginId ?? '?'}" could not register route '
            '"$route": ${e.message}',
        pluginId: currentPluginId,
        resourceId: route,
      );
    }
  }

  @override
  void declareExtensionPoint<T>(String id) {
    final existing = _extensionPointTypes[id];
    if (existing != null) {
      throw CliPluginError(
        'PLUGIN_EXTENSION_POINT_DUPLICATE',
        'Plugin "${currentPluginId ?? '?'}" declared extension point "$id" a '
            'second time; it was already declared for $existing.',
        pluginId: currentPluginId,
        resourceId: id,
      );
    }
    _extensionPointTypes[id] = T;
    _contributions.putIfAbsent(id, () => []);
  }

  @override
  void contribute<T>(String extensionPointId, T value) {
    final declaredType = _extensionPointTypes[extensionPointId];
    if (declaredType == null) {
      throw CliPluginError(
        'PLUGIN_EXTENSION_POINT_UNDECLARED',
        'Plugin "${currentPluginId ?? '?'}" contributed to extension point '
            '"$extensionPointId", which no plugin declared.',
        pluginId: currentPluginId,
        resourceId: extensionPointId,
      );
    }
    if (declaredType != T) {
      throw CliPluginError(
        'PLUGIN_EXTENSION_POINT_TYPE_MISMATCH',
        'Plugin "${currentPluginId ?? '?'}" contributed a $T to extension '
            'point "$extensionPointId", which was declared for $declaredType.',
        pluginId: currentPluginId,
        resourceId: extensionPointId,
      );
    }
    _contributions[extensionPointId]!.add(value);
  }

  @override
  List<T> contributions<T>(String extensionPointId) {
    final declaredType = _extensionPointTypes[extensionPointId];
    if (declaredType == null) {
      throw CliPluginError(
        'PLUGIN_EXTENSION_POINT_UNDECLARED',
        'Plugin "${currentPluginId ?? '?'}" read contributions for '
            'extension point "$extensionPointId", which no plugin declared.',
        pluginId: currentPluginId,
        resourceId: extensionPointId,
      );
    }
    if (declaredType != T) {
      throw CliPluginError(
        'PLUGIN_EXTENSION_POINT_TYPE_MISMATCH',
        'Plugin "${currentPluginId ?? '?'}" read contributions for '
            'extension point "$extensionPointId" as $T, which was declared '
            'for $declaredType.',
        pluginId: currentPluginId,
        resourceId: extensionPointId,
      );
    }
    return List<T>.unmodifiable(_contributions[extensionPointId] ?? const []);
  }
}
