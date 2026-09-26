import 'cli_contract.dart';
import 'cli_param.dart';
import 'cli_positional.dart';
import 'route_pattern.dart';

/// Which of the two kinds of unit a route was registered as.
///
/// Not an annotation on a command but a consequence of how it was registered,
/// and of which contract it implements. A [CommandKind.query] has no preview
/// because it has nothing to preview, which is why `--plan` and `--apply` are
/// rejected on one without any command author writing a line.
enum CommandKind {
  /// Reads and answers. Changes nothing.
  query,

  /// Changes something, through steps that say what they would do first.
  command,
}

/// The declared contract of one registered command.
class CommandContract {
  CommandContract({
    required this.route,
    required this.module,
    required this.contract,
    required this.globals,
    this.kind = CommandKind.command,
    this.description,
  });

  /// Full route as registered, mount prefix and positionals included:
  /// `records show <id>`.
  final String route;

  /// The route without its positional placeholders or trailing wildcard:
  /// the tokens a user types to name the command: `records show`, `help`.
  /// This is how a command is *named*, as opposed to how it is *invoked*,
  /// and it is what help is asked about.
  ///
  /// Strips a trailing optional `[<name>]` placeholder exactly as it strips
  /// a required `<name>` one: `eval rpn [<program>]` is named `eval rpn`,
  /// the same name a caller types whether or not they go on to supply the
  /// optional positional.
  String get name =>
      route.replaceAll(RegExp(r'\s*(\[<[^>]+>\]|<[^>]+>|\*)'), '').trim();

  /// The route exactly as `cli_router`'s own `CliRoute.pattern` reports it:
  /// every segment except a trailing optional positional or wildcard, which
  /// `cli_router` never includes there. Unlike [route] (this SDK's own
  /// record of the full pattern) and [name] (words only, no placeholders at
  /// all), this is what [CommandCatalog.forRoute] must match a
  /// [CliRejection]'s `route.pattern` against: the router reports
  /// `eval rpn`, never `eval rpn [<program>]`.
  String get routerPattern => RoutePattern(route).routerPattern;

  /// Module the command belongs to; empty for a root command.
  final String module;

  /// Whether this route reads or changes. Published in help so a reader — a
  /// person or an agent — can tell the two apart without running either.
  final CommandKind kind;

  final String? description;

  /// Whether this route accepts the global options (`--json`, `--quiet`,
  /// `--help`) alongside its own declared contract. Stored here, not just
  /// passed to `cli_router.cmd`, so help can render exactly the options a
  /// route actually accepts: a route registered `globals: false` never
  /// takes `--json`/`--quiet`/`--help`, and listing them anyway told a
  /// reader to type something the route itself would then reject.
  final bool globals;

  /// The command's full declared contract: its options, its positionals, and
  /// the cross-field rules that hold between them.
  ///
  /// Always present: a command with nothing to declare says so explicitly
  /// with [CliContract.none] rather than leaving the field absent. There is
  /// no undeclared escape hatch: what is not in [contract] is not accepted.
  final CliContract contract;

  /// The declared options: kept for callers that only care about options,
  /// and for backward-readable help rendering.
  List<CliParam> get declaredParams => contract.options;

  List<CliPositional> get positionals => contract.positionals;

  List<CliParam> get options => contract.options;

  Map<String, dynamic> toJson() => {
    'route': route,
    'kind': kind.name,
    'globals': globals,
    if (module.isNotEmpty) 'module': module,
    if (description != null) 'description': description,
    ...contract.toJson(),
  };
}

/// Every command the CLI has registered, as declared at registration.
///
/// This is the single source help is rendered from — the CLI analogue of the
/// registry `modular_api` generates its OpenAPI document from.
class CommandCatalog {
  final List<CommandContract> _contracts = [];

  List<CommandContract> get commands => List.unmodifiable(_contracts);

  void register(CommandContract contract) => _contracts.add(contract);

  /// The contract for an exact route, matched against [routerPattern]:
  /// `cli_router`'s own [CliRoute.pattern] never includes a trailing
  /// optional positional or wildcard, so neither does this match, even
  /// though [CommandContract.route] (this SDK's full record) does.
  CommandContract? forRoute(String routerPattern) {
    for (final contract in _contracts) {
      if (contract.routerPattern == routerPattern) return contract;
    }
    return null;
  }

  /// The contract a user *names*: matched on the route without its positional
  /// placeholders, so `show` finds `show <id>`. Asking a command how it is used
  /// must not require already supplying the argument being asked about.
  CommandContract? forName(String name) {
    for (final contract in _contracts) {
      if (contract.name == name) return contract;
    }
    return null;
  }

  /// Every command registered under [name], in registration order: unlike
  /// [forName], which answers a human's "how is `x` used" with the single
  /// best match, this exposes every one, since two distinct routes can
  /// share the exact same words-only name and differ only in how many
  /// positionals follow it (`s` and `s <id> <sub>` are both named `s`,
  /// positionals stripped). Callers that must not silently pick one of
  /// several such routes use this instead of [forName] (round-9 review
  /// findings 3 and 4).
  List<CommandContract> allForName(String name) =>
      _contracts.where((c) => c.name == name).toList();

  /// Every command registered under a module.
  List<CommandContract> forModule(String module) =>
      _contracts.where((c) => c.module == module).toList();

  /// Every registered route of one kind.
  List<CommandContract> ofKind(CommandKind kind) =>
      _contracts.where((c) => c.kind == kind).toList();

  /// Whether both kinds are registered. Help lists them apart only then — a CLI
  /// that is all one kind has nothing to tell apart, and two headings over one
  /// list would be noise.
  bool get hasBothKinds =>
      _contracts.any((c) => c.kind == CommandKind.query) &&
      _contracts.any((c) => c.kind == CommandKind.command);

  bool get isEmpty => _contracts.isEmpty;

  /// The registered route word closest to [word], for a rejection message
  /// like "did you mean 'show'?", or `null` when nothing registered is
  /// close enough.
  ///
  /// The candidate vocabulary is every distinct literal word that appears
  /// anywhere across every registered command's [CommandContract.name]
  /// (split on whitespace), so `eval rpn` contributes both `eval` and
  /// `rpn`. This is scoped to the whole catalog, not to where in the route
  /// tree the typo actually occurred (`cli_router`'s trie is private and
  /// not introspectable from this SDK, so a suggestion can, in principle,
  /// name a word that is not reachable from the caller's actual position).
  /// In practice route vocabularies rarely collide across unrelated
  /// modules, and a wrong-but-plausible suggestion is still more useful
  /// than none.
  ///
  /// Closeness is the restricted edit distance between [word] and each
  /// candidate: Levenshtein distance (insertion, deletion, substitution)
  /// plus one more operation, transposing two adjacent characters, counted
  /// as a single edit (the "Damerau" part of Damerau-Levenshtein, in its
  /// cheaper OSA/restricted form: each substring is only ever transposed
  /// once). A candidate must be within [maxDistance] edits to be returned
  /// at all: 2 catches a typo like `shwo` -> `show` (distance 1,
  /// transposition) without also matching words that merely happen to
  /// share a few letters. Ties (more than one candidate at the minimum
  /// distance found) are broken by catalog order: the order routes were
  /// registered in, the same order [commands] reports.
  ///
  /// [maxDistance] is required: this catalog has no distance of its own to
  /// fall back to, and a caller that does not say how tolerant to be would
  /// otherwise get a silently chosen one, which could disagree with
  /// whatever distance the rest of the CLI is configured with. `ModularCli`
  /// is the usual caller; it always threads its own configured distance
  /// through explicitly.
  String? suggest(String word, {required int maxDistance}) {
    final vocabulary = <String>[];
    final seen = <String>{};
    for (final contract in _contracts) {
      for (final w in contract.name.split(' ')) {
        if (w.isEmpty) continue;
        if (seen.add(w)) vocabulary.add(w);
      }
    }

    String? best;
    var bestDistance = maxDistance + 1;
    for (final candidate in vocabulary) {
      final distance = _restrictedEditDistance(word, candidate);
      if (distance < bestDistance) {
        bestDistance = distance;
        best = candidate;
      }
    }
    return bestDistance <= maxDistance ? best : null;
  }
}

/// Restricted edit distance (a.k.a. optimal string alignment / OSA):
/// Levenshtein distance extended with one more edit, transposing two
/// adjacent characters, each substring transposed at most once. Standard
/// dynamic-programming table, `O(|a| * |b|)`.
int _restrictedEditDistance(String a, String b) {
  final m = a.length;
  final n = b.length;
  final d = List.generate(m + 1, (_) => List<int>.filled(n + 1, 0));
  for (var i = 0; i <= m; i++) {
    d[i][0] = i;
  }
  for (var j = 0; j <= n; j++) {
    d[0][j] = j;
  }
  for (var i = 1; i <= m; i++) {
    for (var j = 1; j <= n; j++) {
      final cost = a[i - 1] == b[j - 1] ? 0 : 1;
      var value = [
        d[i - 1][j] + 1, // deletion
        d[i][j - 1] + 1, // insertion
        d[i - 1][j - 1] + cost, // substitution
      ].reduce((x, y) => x < y ? x : y);
      if (i > 1 && j > 1 && a[i - 1] == b[j - 2] && a[i - 2] == b[j - 1]) {
        value = value < d[i - 2][j - 2] + 1 ? value : d[i - 2][j - 2] + 1;
      }
      d[i][j] = value;
    }
  }
  return d[m][n];
}
