import 'package:cli_router/cli_router.dart';

import 'cli_param.dart';

/// The options the framework handles for every command, whatever it declares.
///
/// One declaration, three readers: help documents them once as global
/// options, `ModularCli` registers [globalOptionSpecs] with `cli_router` so
/// they are in scope everywhere, and `ModuleBuilder` acts on them when it
/// picks the output mode.
final List<CliParam> globalOptions = [
  CliParam.flag(
    'json',
    repeatable: false,
    description: 'Emit machine-readable JSON',
  ),
  CliParam.flag(
    'quiet',
    abbr: 'q',
    repeatable: false,
    description: 'Suppress non-essential output',
  ),
  CliParam.flag(
    'help',
    abbr: 'h',
    repeatable: false,
    description: 'Show this contract',
  ),
];

/// Every name a global option answers to.
final Set<String> globalOptionNames = {
  for (final option in globalOptions) ...[option.name, ...option.aliases],
};

/// [globalOptions] translated into the shape `CliRouter` registers.
final List<OptionSpec> globalOptionSpecs = [
  for (final option in globalOptions) option.toOptionSpec(),
];
