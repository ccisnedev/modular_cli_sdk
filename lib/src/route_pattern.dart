import 'cli_contract.dart';

/// The kind of one segment of a route pattern.
enum RouteSegKind {
  /// A fixed word the caller must type verbatim: `show`.
  literal,

  /// `<name>`: a positional that must be present.
  requiredParam,

  /// `[<name>]`: a positional that may be omitted; only ever the last
  /// segment of a pattern.
  optionalParam,

  /// `*`: collects every remaining token; only ever the last segment.
  wildcard,
}

/// One segment of a parsed [RoutePattern].
class RouteSeg {
  const RouteSeg._(this.kind, this.text, this.name);

  factory RouteSeg.literal(String text) =>
      RouteSeg._(RouteSegKind.literal, text, null);
  factory RouteSeg.requiredParam(String name) =>
      RouteSeg._(RouteSegKind.requiredParam, null, name);
  factory RouteSeg.optionalParam(String name) =>
      RouteSeg._(RouteSegKind.optionalParam, null, name);
  factory RouteSeg.wildcard() =>
      const RouteSeg._(RouteSegKind.wildcard, null, null);

  final RouteSegKind kind;
  final String? text;
  final String? name;
}

/// Parses a `cli_router` route pattern the same way `cli_router` itself
/// does, so this SDK can reason, at registration time and before the router
/// ever sees the pattern, about which positionals a route declares, which
/// one (if any) is the trailing optional positional, and whether it ends in
/// a wildcard.
///
/// This mirrors `cli_router`'s own private `_parseSegments`/grammar
/// (`trie.dart`, spec "Grammar G"): route words are literals, params are
/// operands, options go before operands, and only the very last segment may
/// be `[<name>]` or `*`. Kept in lockstep with that grammar deliberately:
/// this SDK validates a declared [CliContract] against a route pattern
/// *before* handing either to `cli_router`, so its own parse must agree
/// with the router's or a contract that looks valid here could still be
/// rejected there, or vice versa.
class RoutePattern {
  RoutePattern(this.pattern) : segments = _parse(pattern);

  final String pattern;
  final List<RouteSeg> segments;

  static final _letter = RegExp(r'^[A-Za-z]$');

  static bool _looksLikeOption(String token) {
    if (token == '--') return true;
    if (token.length < 2 || token[0] != '-') return false;
    if (token[1] == '-') {
      if (token.length < 3) return false;
      return _letter.hasMatch(token[2]);
    }
    return _letter.hasMatch(token[1]);
  }

  static List<RouteSeg> _parse(String pattern) {
    final words = pattern
        .trim()
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .toList();
    final segs = <RouteSeg>[];
    var paramSeen = false;
    for (var idx = 0; idx < words.length; idx++) {
      final w = words[idx];
      final isLast = idx == words.length - 1;
      if (w == '*') {
        if (!isLast) {
          throw ArgumentError.value(
            pattern,
            'pattern',
            "'*' must be the last segment",
          );
        }
        segs.add(RouteSeg.wildcard());
        paramSeen = true;
      } else if (w.startsWith('[<') && w.endsWith('>]') && w.length > 4) {
        if (!isLast) {
          throw ArgumentError.value(
            pattern,
            'pattern',
            '[<name>] must be the last segment',
          );
        }
        segs.add(RouteSeg.optionalParam(w.substring(2, w.length - 2)));
        paramSeen = true;
      } else if (w.startsWith('<') && w.endsWith('>') && w.length > 2) {
        segs.add(RouteSeg.requiredParam(w.substring(1, w.length - 1)));
        paramSeen = true;
      } else {
        if (_looksLikeOption(w)) {
          throw ArgumentError.value(
            pattern,
            'pattern',
            "'$w' looks like an option and cannot be a literal route "
                'segment',
          );
        }
        if (paramSeen) {
          throw ArgumentError.value(
            pattern,
            'pattern',
            "'$w' is a literal route word after a parameter; route words "
                'must come before every parameter',
          );
        }
        segs.add(RouteSeg.literal(w));
      }
    }
    return segs;
  }

  /// Names of every required `<name>` positional, in declaration order.
  List<String> get requiredPositionals => [
    for (final s in segments)
      if (s.kind == RouteSegKind.requiredParam) s.name!,
  ];

  /// Name of the trailing optional `[<name>]` positional, or `null`.
  String? get optionalPositional {
    if (segments.isEmpty) return null;
    final last = segments.last;
    return last.kind == RouteSegKind.optionalParam ? last.name : null;
  }

  /// Whether the pattern ends in `*`.
  bool get hasWildcard =>
      segments.isNotEmpty && segments.last.kind == RouteSegKind.wildcard;

  /// Every positional name this pattern binds, required ones first, then the
  /// trailing optional one (if any): the same order `cli_router` itself
  /// reports as `CliRoute.positionals`.
  List<String> get positionals => [
    ...requiredPositionals,
    if (optionalPositional != null) optionalPositional!,
  ];

  /// The pattern as `cli_router` stores it on `CliRoute.pattern`: every
  /// segment except a trailing optional param or wildcard, which never
  /// appear there.
  String get routerPattern {
    final publicSegs = (hasWildcard || optionalPositional != null)
        ? segments.sublist(0, segments.length - 1)
        : segments;
    return _toPatternString(publicSegs);
  }

  /// The route's leading literal words alone, every parameter and wildcard
  /// segment dropped, not just a trailing optional one.
  ///
  /// This is the identity `cli_router` reports back on a rejection that
  /// never resolved a specific route at all (`CliRejection.route == null`):
  /// `CliRejection.consumed` only ever accumulates literal words matched
  /// while walking the trie (grammar G puts every literal before every
  /// parameter, so there is exactly one literal run, at the front), never a
  /// parameter's bound value. For a route with no required positional this
  /// is the same string as [routerPattern]; for one with a required
  /// positional (`s <id>`) it is shorter, dropping `<id>` too.
  String get literalPrefix => _toPatternString(
    segments.takeWhile((s) => s.kind == RouteSegKind.literal).toList(),
  );

  static String _toPatternString(List<RouteSeg> segs) => segs
      .map((s) {
        switch (s.kind) {
          case RouteSegKind.literal:
            return s.text!;
          case RouteSegKind.requiredParam:
            return '<${s.name}>';
          case RouteSegKind.optionalParam:
            return '[<${s.name}>]';
          case RouteSegKind.wildcard:
            return '*';
        }
      })
      .join(' ');
}

/// Checks that [contract]'s declared positionals match [route]'s positional
/// segments exactly: same names, same order, same required/optional
/// cardinality, no duplicates. Throws [ArgumentError] (a registration-time,
/// build-time mistake, never a runtime rejection) the moment any of that
/// does not hold.
///
/// This is what makes a mismatch like `show <id>` registered against
/// `CliPositional.integer('typo')` fail loudly when the route is declared,
/// instead of quietly accepting every invocation because nothing ever
/// checked that the declared positional and the route's actual `<id>`
/// segment were the same thing.
void validateContractPositionals(String route, CliContract contract) {
  final pattern = RoutePattern(route);
  final routePositionals = pattern.positionals;
  final declared = contract.positionals;

  final seen = <String>{};
  for (final positional in declared) {
    if (!seen.add(positional.name)) {
      throw ArgumentError(
        'Route "$route" declares positional "${positional.name}" more '
        'than once.',
      );
    }
  }

  if (declared.length != routePositionals.length) {
    throw ArgumentError(
      'Route "$route" has ${routePositionals.length} positional segment(s) '
      '(${routePositionals.isEmpty ? 'none' : routePositionals.join(', ')}) '
      'but its contract declares ${declared.length} positional(s) '
      '(${declared.isEmpty ? 'none' : declared.map((p) => p.name).join(', ')}).',
    );
  }

  for (var i = 0; i < routePositionals.length; i++) {
    final routeName = routePositionals[i];
    final declaredName = declared[i].name;
    if (routeName != declaredName) {
      throw ArgumentError(
        'Route "$route" positional #${i + 1} is "<$routeName>" but its '
        'contract declares "$declaredName" in that position.',
      );
    }
  }

  final optionalName = pattern.optionalPositional;
  for (final positional in declared) {
    final isRouteOptional = positional.name == optionalName;
    if (isRouteOptional && positional.required) {
      throw ArgumentError(
        'Route "$route" declares "<${positional.name}>" as optional '
        '(`[<${positional.name}>]`) but its contract declares '
        '"${positional.name}" as required. Declare it with '
        '`required: false`.',
      );
    }
    if (!isRouteOptional && !positional.required) {
      throw ArgumentError(
        'Route "$route" declares "<${positional.name}>" as required but '
        'its contract declares "${positional.name}" as optional '
        '(`required: false`). Only the trailing `[<${positional.name}>]` '
        'segment of a route may be optional.',
      );
    }
  }
}
