import 'cli_param.dart';
import 'command_catalog.dart';
import 'global_options.dart';

/// Renders the command catalog as the plain, aligned text a user reads.
///
/// The renderer is the only place help text is produced: the command list, the
/// focused help of a single command or module, and the error path all come
/// from here, so a user never sees two descriptions of the same CLI.
class HelpRenderer {
  HelpRenderer(this.catalog);

  final CommandCatalog catalog;

  /// Every registered command with its description, plus the global options.
  String renderCatalog() {
    final lines = <String>['Commands:', ..._commandLines(catalog.commands), ''];
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
    if (contract.declaredParams.isNotEmpty) {
      lines
        ..add('')
        ..add('Parameters:')
        ..addAll(_paramLines(contract.declaredParams));
    }
    lines
      ..add('')
      ..addAll(_globalOptionsSection());
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
      lines.addAll(_paramLines(contract.declaredParams).map((line) => '  $line'));
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

  List<String> _globalOptionsSection() => [
    'Global options:',
    ..._paramLines(globalOptions),
  ];

  /// `-a, --a <int>` / `--verbose` / `<id>`.
  String _invocationLabelOf(CliParam param) {
    if (param.kind == CliParamKind.positional) return '<${param.name}>';
    final abbr = param.abbr == null ? '    ' : '-${param.abbr}, ';
    final value = param.kind == CliParamKind.flag
        ? ''
        : ' <${_valueLabelOf(param.type)}>';
    return '$abbr--${param.name}$value';
  }

  String _valueLabelOf(CliParamType type) => switch (type) {
    CliParamType.string => 'string',
    CliParamType.integer => 'int',
    CliParamType.number => 'num',
    CliParamType.boolean => 'bool',
  };

  /// `First operand (required)` / `Greeting target (default: World)`.
  String _facetsOf(CliParam param) {
    final facets = <String>[
      if (param.required) 'required',
      if (param.defaultValue != null) 'default: ${param.defaultValue}',
      if (param.allowed != null) 'one of: ${param.allowed!.join(', ')}',
    ];
    final description = param.description ?? '';
    if (facets.isEmpty) return description;
    return '$description (${facets.join(', ')})'.trimLeft();
  }

  String _usageOf(CommandContract contract) {
    final positionals = contract.positionals
        .map((p) => '<${p.name}>')
        .join(' ');
    final route = contract.route.replaceAll(RegExp(r'\s*<[^>]+>'), '');
    return [
      route,
      if (positionals.isNotEmpty) positionals,
      if (contract.options.isNotEmpty) '[options]',
    ].join(' ');
  }

  int _widestOf(Iterable<String> values) => values.fold<int>(
    0,
    (widest, value) => value.length > widest ? value.length : widest,
  );
}
