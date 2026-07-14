import 'cli_param.dart';

/// The options the framework handles for every command, whatever it declares.
///
/// One declaration, three readers: help documents them once as global options,
/// the contract enforcement accepts them on any command, and `ModuleBuilder`
/// acts on them when it picks the output mode.
final List<CliParam> globalOptions = [
  CliParam.boolean('json', description: 'Emit machine-readable JSON'),
  CliParam.boolean(
    'quiet',
    abbr: 'q',
    description: 'Suppress non-essential output',
  ),
  CliParam.boolean('help', abbr: 'h', description: 'Show this contract'),
];

/// Every name a global option answers to.
final Set<String> globalOptionNames = {
  for (final option in globalOptions) ...[option.name, ...option.aliases],
};
