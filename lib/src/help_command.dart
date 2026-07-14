import 'command.dart';
import 'command_catalog.dart';
import 'exit_codes.dart';
import 'global_options.dart';
import 'help_renderer.dart';
import 'input.dart';
import 'output.dart';

/// Help is a command like any other: it runs the lifecycle, writes to stdout,
/// and exits 0. Only unknown or invalid usage is a failure.
class HelpCommand implements Command<HelpInput, HelpOutput> {
  HelpCommand(this.input);

  @override
  final HelpInput input;

  @override
  String? validate() => null;

  @override
  Future<HelpOutput> execute() async =>
      HelpOutput(input.catalog, focus: input.focus);
}

class HelpInput extends Input {
  HelpInput(this.catalog, {this.focus = const []});

  final CommandCatalog catalog;

  /// The command or module help was asked about: `help math add` → the command;
  /// `help math` → the module; empty → the whole CLI.
  final List<String> focus;

  @override
  Map<String, dynamic> toJson() => {};
}

/// The catalog in whichever form the active output mode asks for: aligned text
/// for a human, the full contract catalog for `--json` (`help.json`).
class HelpOutput extends Output {
  HelpOutput(this.catalog, {this.focus = const []});

  final CommandCatalog catalog;
  final List<String> focus;

  @override
  Map<String, dynamic> toJson() {
    final contract = _focusedCommand;
    if (contract != null) return contract.toJson();

    final moduleCommands = _focusedModuleCommands;
    return {
      'commands': (moduleCommands ?? catalog.commands)
          .map((c) => c.toJson())
          .toList(),
      'globalOptions': globalOptions.map((o) => o.toJson()).toList(),
    };
  }

  @override
  String? toText() {
    final renderer = HelpRenderer(catalog);
    final contract = _focusedCommand;
    if (contract != null) return renderer.renderCommand(contract);
    if (_focusedModuleCommands != null) {
      return renderer.renderModule(_focusName);
    }
    return renderer.renderCatalog();
  }

  @override
  int get exitCode => ExitCode.ok;

  String get _focusName => focus.join(' ');

  CommandContract? get _focusedCommand =>
      focus.isEmpty ? null : catalog.forRoute(_focusName);

  /// Null when help was not asked about a module.
  List<CommandContract>? get _focusedModuleCommands {
    if (focus.isEmpty) return null;
    final commands = catalog.forModule(_focusName);
    return commands.isEmpty ? null : commands;
  }
}
