import 'command.dart';
import 'command_catalog.dart';
import 'exit_codes.dart';
import 'global_options.dart';
import 'help_renderer.dart';
import 'input.dart';
import 'output.dart';

/// Help is a command like any other: it runs the same lifecycle, writes to
/// stdout, and exits 0. Only unknown or invalid usage is a failure.
class HelpCommand implements Command<HelpInput, HelpOutput> {
  HelpCommand(this.input);

  @override
  final HelpInput input;

  @override
  String? validate() => null;

  @override
  Future<HelpOutput> execute() async => HelpOutput(input.catalog);
}

class HelpInput extends Input {
  HelpInput(this.catalog);

  final CommandCatalog catalog;

  @override
  Map<String, dynamic> toJson() => {};
}

/// The catalog, in whichever form the active output mode asks for: aligned text
/// for a human, the full contract catalog for `--json` (`help.json`).
class HelpOutput extends Output {
  HelpOutput(this.catalog);

  final CommandCatalog catalog;

  @override
  Map<String, dynamic> toJson() => {
    'commands': catalog.commands.map((c) => c.toJson()).toList(),
    'globalOptions': globalOptions.map((o) => o.toJson()).toList(),
  };

  @override
  String? toText() => HelpRenderer(catalog).renderCatalog();

  @override
  int get exitCode => ExitCode.ok;
}
