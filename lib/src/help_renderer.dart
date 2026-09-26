import 'cli_param.dart';
import 'cli_positional.dart';
import 'command_catalog.dart';
import 'global_options.dart';
import 'route_pattern.dart';

/// Renders the command catalog as the plain, aligned text a user reads.
///
/// The renderer is the only place help text is produced: the command list, the
/// focused help of a single command or module, and the error path all come
/// from here, so a user never sees two descriptions of the same CLI.
class HelpRenderer {
  HelpRenderer(this.catalog);

  final CommandCatalog catalog;

  /// Every registered route with its description, plus the global options.
  ///
  /// When the CLI has both kinds, what reads is listed apart from what changes:
  /// "which of these is safe to just try?" is the first question a person has
  /// about an unfamiliar CLI, and the listing is where they look for it.
  ///
  /// A CLI of a single kind keeps one list. Two headings over one list would be
  /// noise, and it is the shape of every CLI written before commands existed.
  String renderCatalog() {
    final lines = <String>[
      if (catalog.hasBothKinds) ...[
        'Queries:',
        ..._commandLines(catalog.ofKind(CommandKind.query)),
        '',
        'Commands:',
        ..._commandLines(catalog.ofKind(CommandKind.command)),
      ] else ...[
        'Commands:',
        ..._commandLines(catalog.commands),
      ],
      '',
    ];
    lines.addAll(_globalOptionsSection());
    return lines.join('\n');
  }

  /// One command's full contract: how to invoke it and every parameter it takes.
  String renderCommand(CommandContract contract) {
    final lines = <String>['Usage: ${_usageOf(contract)}'];
    if (contract.description != null) {
      lines
        ..add('')
        ..add(contract.description!);
    }
    if (contract.positionals.isNotEmpty) {
      lines
        ..add('')
        ..add('Positional arguments:')
        ..addAll(_positionalLines(contract.positionals));
    }
    if (contract.declaredParams.isNotEmpty) {
      lines
        ..add('')
        ..add('Parameters:')
        ..addAll(_paramLines(contract.declaredParams));
    }
    if (contract.globals) {
      lines
        ..add('')
        ..addAll(_globalOptionsSection());
    }
    return lines.join('\n');
  }

  /// Every command under a module, each with its parameters.
  String renderModule(String module) {
    final contracts = catalog.forModule(module);
    final lines = <String>['Commands in $module:'];
    for (final contract in contracts) {
      lines
        ..add('')
        ..add('  ${contract.route}${_descriptionSuffixOf(contract)}');
      lines.addAll(
        _paramLines(contract.declaredParams).map((line) => '  $line'),
      );
    }
    lines
      ..add('')
      ..addAll(_globalOptionsSection());
    return lines.join('\n');
  }

  String _descriptionSuffixOf(CommandContract contract) =>
      contract.description == null ? '' : '  ${contract.description}';

  /// How the root route is named in the listing: it has no token to type, so it
  /// is named by the only way it can be invoked — with nothing at all. Without
  /// this it rendered as a description hanging off a blank column.
  static const String rootRouteLabel = '(no arguments)';

  String _listingNameOf(CommandContract contract) =>
      contract.route.isEmpty ? rootRouteLabel : contract.route;

  List<String> _commandLines(List<CommandContract> contracts) {
    final names = {for (final c in contracts) c: _listingNameOf(c)};
    final width = _widestOf(names.values);
    return [
      for (final contract in contracts)
        '  ${names[contract]!.padRight(width)}  ${contract.description ?? ''}'
            .trimRight(),
    ];
  }

  List<String> _paramLines(List<CliParam> params) {
    final labels = {
      for (final param in params) param: _invocationLabelOf(param),
    };
    final width = _widestOf(labels.values);
    return [
      for (final param in params)
        '  ${labels[param]!.padRight(width)}  ${_facetsOf(param)}'.trimRight(),
    ];
  }

  List<String> _positionalLines(List<CliPositional> positionals) {
    final labels = {
      for (final positional in positionals) positional: '<${positional.name}>',
    };
    final width = _widestOf(labels.values);
    return [
      for (final positional in positionals)
        '  ${labels[positional]!.padRight(width)}  ${_positionalFacetsOf(positional)}'
            .trimRight(),
    ];
  }

  List<String> _globalOptionsSection() => [
    'Global options:',
    ..._paramLines(globalOptions),
  ];

  /// `-a, --a <int>` / `--verbose`.
  String _invocationLabelOf(CliParam param) {
    final abbr = param.abbr == null ? '    ' : '-${param.abbr}, ';
    final value = param.isFlag ? '' : ' <${_valueLabelOf(param.type)}>';
    return '$abbr--${param.name}$value';
  }

  String _valueLabelOf(CliParamType type) => switch (type) {
    CliParamType.flag => '',
    CliParamType.string => 'string',
    CliParamType.integer => 'int',
    CliParamType.number => 'num',
    CliParamType.enumeration => 'enum',
    CliParamType.path => 'path',
  };

  /// `First operand (required)` / `Greeting target (default: World, the
  /// name used when nobody gave one)`.
  String _facetsOf(CliParam param) {
    final facets = <String>[
      if (param.required) 'required',
      if (param.repeatable) 'repeatable',
      if (param.defaultValue != null)
        'default: ${param.defaultValue!.value}, ${param.defaultValue!.reason}',
      if (param.values != null) 'one of: ${param.values!.join(', ')}',
      if (param.mustExist == true) 'must exist',
    ];
    final description = param.description ?? '';
    if (facets.isEmpty) return description;
    return '$description (${facets.join(', ')})'.trimLeft();
  }

  String _positionalFacetsOf(CliPositional positional) {
    final facets = <String>[
      if (positional.required) 'required' else 'optional',
      if (positional.values != null) 'one of: ${positional.values!.join(', ')}',
    ];
    final description = positional.description ?? '';
    if (facets.isEmpty) return description;
    return '$description (${facets.join(', ')})'.trimLeft();
  }

  String _usageOf(CommandContract contract) {
    final positionals = contract.positionals
        .map((p) => p.required ? '<${p.name}>' : '[<${p.name}>]')
        .join(' ');
    final route = contract.route.replaceAll(
      RegExp(r'\s*(\[<[^>]+>\]|<[^>]+>|\*)'),
      '',
    );
    final hasWildcard = RoutePattern(contract.route).hasWildcard;
    // `cli_router`'s grammar requires every option to precede the first
    // positional on the actual command line (spec 8.2: "options go before
    // the program"), so the usage line is written in that same order,
    // rather than the more familiar `<name> [options]` a reader might
    // expect from other CLIs, to avoid showing an invocation the router
    // would then reject.
    return [
      route,
      if (contract.options.isNotEmpty) '[options]',
      if (positionals.isNotEmpty) positionals,
      if (hasWildcard) '*',
    ].join(' ');
  }

  int _widestOf(Iterable<String> values) => values.fold<int>(
    0,
    (widest, value) => value.length > widest ? value.length : widest,
  );
}
