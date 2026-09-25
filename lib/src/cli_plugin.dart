import 'package:cli_router/cli_router.dart';
import 'package:pub_semver/pub_semver.dart' as semver;

import 'cli_contract.dart';
import 'command.dart';
import 'input.dart';
import 'output.dart';
import 'query.dart';

/// The plugin host API's own version, independent of the `modular_cli_sdk`
/// package version, and the number a plugin's
/// [CliPluginManifest.hostApiVersion] constraint is checked against.
///
/// A package version bump does not have to mean a host API bump: this only
/// moves when [CliPluginHost]'s shape changes in a way a plugin could depend
/// on.
const String cliPluginHostApiVersion = '1.0.0';

/// Builds a [Query] from a request, at whatever concrete `I`/`O` the plugin
/// declared, accepted by [CliPluginHost.registerQuery] through the ordinary
/// covariance of a function returning a subtype.
typedef QueryFactory = Query<Input, Output> Function(CliRequest req);

/// Builds a [Command] from a request, symmetric with [QueryFactory].
typedef CommandFactory = Command<Input, Output> Function(CliRequest req);

/// What a plugin is, declared without saying what it does.
///
/// [id] is the identity other plugins reference in [requires], and the one a
/// build-time failure names. [hostApiVersion] is a semver constraint (`^1.0.0`,
/// `>=1.0.0 <2.0.0`, …) checked against [cliPluginHostApiVersion]: not a
/// literal version, because a plugin is written once against a range, not
/// against whatever a single host build happens to be.
class CliPluginManifest {
  const CliPluginManifest({
    required this.id,
    required this.displayName,
    required this.version,
    required this.hostApiVersion,
    this.requires = const [],
  });

  /// Stable, unique identifier, e.g. `modular_cli.doctor`.
  final String id;

  /// Human-readable name, used in help and error text.
  final String displayName;

  /// This plugin's own version.
  final String version;

  /// A semver constraint against [cliPluginHostApiVersion].
  final String hostApiVersion;

  /// Ids of plugins that must be registered, and set up, before this one.
  final List<String> requires;
}

/// A unit of CLI functionality distributed independently of the host that
/// runs it.
///
/// A plugin declares what it is through [manifest], and registers itself
/// (routes, extension points, contributions) through [setup], which the host
/// calls exactly once per plugin, in dependency order.
abstract class CliPlugin {
  CliPluginManifest get manifest;

  void setup(CliPluginHost host);
}

/// What the host that is running this CLI is called, and which version of it
/// this is: the one piece of runtime information a plugin cannot declare
/// about itself, because it is a fact about the host, not the plugin.
///
/// Supplied via `ModularCli(name: ..., version: ...)`. A plugin that calls
/// [CliPluginHost.metadata] without the host having set it gets a [StateError]:
/// there is no silent placeholder name or version to fall back on.
class CliHostMetadata {
  const CliHostMetadata({required this.name, required this.version});

  final String name;
  final String version;
}

/// What a plugin is given to register itself with, and nothing else.
///
/// Deliberately minimal for this release: no middleware, no capability
/// negotiation beyond [CliPluginManifest.hostApiVersion], no validation hooks,
/// no shutdown. A plugin registers [Query]s and [Command]s exactly as the host
/// application does, declares the extension points other plugins may
/// contribute to, and reads what was contributed to points it declared or
/// knows about.
abstract class CliPluginHost {
  /// The name and version of the CLI this plugin is running inside.
  CliHostMetadata metadata();

  /// Register a root-level [Query], see `ModularCli.query`.
  void registerQuery<I extends Input, O extends Output>(
    String route,
    Query<I, O> Function(CliRequest req) queryFactory, {
    String? description,
    CliContract contract = CliContract.none,
  });

  /// Register a root-level [Command], see `ModularCli.command`.
  void registerCommand<I extends Input, O extends Output>(
    String route,
    Command<I, O> Function(CliRequest req) commandFactory, {
    String? description,
    CliContract contract = CliContract.none,
  });

  /// Declare a point other plugins may contribute values of type [T] to.
  ///
  /// Must be called before any [contribute] to the same [id], which, since
  /// plugins are set up in dependency order, means the plugin that owns the
  /// extension point must be a (possibly transitive) dependency of every
  /// plugin that contributes to it.
  void declareExtensionPoint<T>(String id);

  /// Contribute [value] to the extension point [id].
  ///
  /// Throws [CliPluginError] (`PLUGIN_EXTENSION_POINT_UNDECLARED`) when [id]
  /// was never declared, and (`PLUGIN_EXTENSION_POINT_TYPE_MISMATCH`) when
  /// [T] does not match the type [id] was declared with: a contribution is
  /// checked against the same declaration help would be, not against
  /// whatever the caller happened to pass.
  void contribute<T>(String extensionPointId, T value);

  /// Every value contributed to the extension point [id], in the order the
  /// contributing plugins were set up.
  List<T> contributions<T>(String extensionPointId);
}

/// A build-time failure in assembling the plugin set.
///
/// Always a broken declaration (a duplicate id, a missing dependency, a
/// cycle, an incompatible host API, an undeclared extension point), never
/// something a running CLI recovers from. There is deliberately no fallback
/// for any of these: the offending plugin set does not run, partially or
/// otherwise.
class CliPluginError implements Exception {
  const CliPluginError(
    this.code,
    this.message, {
    this.pluginId,
    this.resourceId,
  });

  /// Machine-readable failure code, `SCREAMING_SNAKE_CASE`.
  final String code;

  final String message;

  /// The plugin whose declaration is at fault.
  final String? pluginId;

  /// The id the declaration pointed at (a required plugin, an extension
  /// point) when the failure is about that reference rather than the
  /// plugin itself.
  final String? resourceId;

  @override
  String toString() => 'CliPluginError($code): $message';
}

enum _VisitState { visiting, visited }

/// Orders [plugins] so each comes after every plugin named in its
/// [CliPluginManifest.requires], directly or transitively (a dependency
/// topological sort), while preserving the original registration order among
/// plugins with no dependency relationship to one another.
///
/// A depth-first visit in registration order does both at once: each plugin
/// pulls its own dependencies in ahead of itself the first time it is
/// visited, and a plugin with no unresolved dependency is appended in the
/// order [plugins] presented it.
///
/// Throws [CliPluginError]:
///  * `PLUGIN_DUPLICATE_ID`: two plugins share an id.
///  * `PLUGIN_DEPENDENCY_MISSING`: a required id is not among [plugins].
///  * `PLUGIN_DEPENDENCY_CYCLE`: a plugin requires itself, directly or
///    through others.
List<CliPlugin> orderCliPlugins(Iterable<CliPlugin> plugins) {
  final pluginList = plugins.toList(growable: false);

  final byId = <String, CliPlugin>{};
  for (final plugin in pluginList) {
    final id = plugin.manifest.id;
    if (byId.containsKey(id)) {
      throw CliPluginError(
        'PLUGIN_DUPLICATE_ID',
        'More than one plugin is registered with id "$id".',
        pluginId: id,
      );
    }
    byId[id] = plugin;
  }

  // Checked once, over every plugin, before the traversal below: the
  // traversal below no longer walks `requires` directly (see [visit]), so it
  // can no longer tell "not required by this plugin" apart from "required but
  // missing" on its own.
  for (final plugin in pluginList) {
    for (final requiredId in plugin.manifest.requires) {
      if (!byId.containsKey(requiredId)) {
        throw CliPluginError(
          'PLUGIN_DEPENDENCY_MISSING',
          'Plugin "${plugin.manifest.id}" requires "$requiredId", which is '
              'not registered.',
          pluginId: plugin.manifest.id,
          resourceId: requiredId,
        );
      }
    }
  }

  final visitState = <String, _VisitState>{};
  final ordered = <CliPlugin>[];

  void visit(CliPlugin plugin) {
    final id = plugin.manifest.id;
    final state = visitState[id];
    if (state == _VisitState.visited) return;
    if (state == _VisitState.visiting) {
      throw CliPluginError(
        'PLUGIN_DEPENDENCY_CYCLE',
        'A plugin dependency cycle was detected at "$id".',
        pluginId: id,
        resourceId: id,
      );
    }

    visitState[id] = _VisitState.visiting;
    // Walked over [pluginList], in registration order, rather than over
    // `plugin.manifest.requires` itself: a plugin naming more than one
    // dependency would otherwise be ordered by the order it *listed* them
    // in, which is not a fact about the plugin set a host controls. Filtering
    // [pluginList] by the required-id set visits the same dependencies, but
    // in the order they were registered, which is what breaks a tie between
    // two of a plugin's own dependencies that have no order relative to each
    // other.
    final requiredIds = plugin.manifest.requires.toSet();
    for (final candidate in pluginList) {
      if (requiredIds.contains(candidate.manifest.id)) {
        visit(candidate);
      }
    }
    visitState[id] = _VisitState.visited;
    ordered.add(plugin);
  }

  for (final plugin in pluginList) {
    visit(plugin);
  }
  return ordered;
}

/// Checks [manifest]'s [CliPluginManifest.hostApiVersion] constraint against
/// [cliPluginHostApiVersion].
///
/// Throws [CliPluginError] (`PLUGIN_INCOMPATIBLE_HOST_API`) when the
/// constraint cannot be parsed as a semver constraint, or parses but does not
/// allow the host's version.
void checkHostApiCompatibility(CliPluginManifest manifest) {
  final semver.VersionConstraint constraint;
  try {
    constraint = semver.VersionConstraint.parse(manifest.hostApiVersion);
  } on FormatException catch (e) {
    throw CliPluginError(
      'PLUGIN_INCOMPATIBLE_HOST_API',
      'Plugin "${manifest.id}" declares an unparseable hostApiVersion '
          '"${manifest.hostApiVersion}": $e',
      pluginId: manifest.id,
    );
  }

  final hostVersion = semver.Version.parse(cliPluginHostApiVersion);
  if (!constraint.allows(hostVersion)) {
    throw CliPluginError(
      'PLUGIN_INCOMPATIBLE_HOST_API',
      'Plugin "${manifest.id}" requires host API '
          '"${manifest.hostApiVersion}", but this SDK provides '
          '$cliPluginHostApiVersion.',
      pluginId: manifest.id,
    );
  }
}
