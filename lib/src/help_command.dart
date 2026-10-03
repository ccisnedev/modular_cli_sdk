import 'command_catalog.dart';
import 'exit_codes.dart';
import 'global_options.dart';
import 'help_renderer.dart';
import 'input.dart';
import 'output.dart';
import 'query.dart';

/// Help is a query like any other: it reads the catalog, writes to stdout, and
/// exits 0. Only unknown or invalid usage is a failure.
///
/// A query rather than a command because it changes nothing — which is also why
/// `help --plan` is rejected, without that having to be arranged.
class HelpQuery implements Query<HelpInput, HelpOutput> {
  HelpQuery(this.input);

  @override
  final HelpInput input;

  @override
  String? validate() => null;

  @override
  Future<HelpOutput> execute() async => HelpOutput(
    input.catalog,
    focus: input.focus,
    programName: input.programName,
    epilog: input.epilog,
  );
}

class HelpInput extends Input {
  HelpInput(
    this.catalog, {
    this.focus = const [],
    this.programName,
    this.epilog,
  });

  final CommandCatalog catalog;

  /// The command or module help was asked about: `help math add` → the command;
  /// `help math` → the module; empty → the whole CLI.
  final List<String> focus;

  /// The host CLI's own name (`ModularCli(name: 'cx')`), or `null` when it
  /// gave none. Threaded through to [HelpRenderer] so a usage line can be
  /// prefixed with it (issue #38).
  final String? programName;

  /// The host CLI's help epilog (issue #50), or `null`.
  final String? epilog;

  @override
  Map<String, dynamic> toJson() => {};
}

/// The catalog in whichever form the active output mode asks for: aligned text
/// for a human, the full contract catalog for `--json` (`help.json`).
class HelpOutput extends Output {
  HelpOutput(
    this.catalog, {
    this.focus = const [],
    this.programName,
    this.epilog,
  });

  final CommandCatalog catalog;
  final List<String> focus;
  final String? programName;

  /// Printed after the full catalog only, never after focused or module help.
  final String? epilog;

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
      if (moduleCommands == null && catalog.rootShortcuts.isNotEmpty)
        'shortcuts': [
          for (final s in catalog.rootShortcuts)
            {...s.toJson(), 'target': s.shortcutTarget},
        ],
      if (moduleCommands == null && epilog != null) 'epilog': epilog,
    };
  }

  @override
  String? toText() {
    final renderer = HelpRenderer(catalog, programName: programName);
    final contract = _focusedCommand;
    if (contract != null) return renderer.renderCommand(contract);
    if (_focusedModuleCommands != null) {
      return renderer.renderModule(_focusName);
    }
    return renderer.renderCatalog(epilog: epilog);
  }

  @override
  int get exitCode => ExitCode.ok;

  String get _focusName => focus.join(' ');

  /// Matched on the command's *name* — the route without its positionals — so
  /// `help show` finds `show <id>` without the caller supplying an id.
  CommandContract? get _focusedCommand =>
      focus.isEmpty ? null : catalog.forName(_focusName);

  /// Null when help was not asked about a module.
  List<CommandContract>? get _focusedModuleCommands {
    if (focus.isEmpty) return null;
    final commands = catalog.forModule(_focusName);
    return commands.isEmpty ? null : commands;
  }
}
