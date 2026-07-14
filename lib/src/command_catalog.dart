import 'cli_param.dart';

/// The declared contract of one registered command.
class CommandContract {
  CommandContract({
    required this.route,
    required this.module,
    required this.params,
    this.description,
  });

  /// Full route as invoked, mount prefix included: `math add`.
  final String route;

  /// Module the command belongs to; empty for a root command.
  final String module;

  final String? description;

  /// Parameters declared by the command's [Input]. Empty when the command
  /// declares none — such a command is described by route and description
  /// alone, and its arguments are not enforced.
  final List<CliParam> params;

  List<CliParam> get positionals =>
      params.where((p) => p.kind == CliParamKind.positional).toList();

  List<CliParam> get options =>
      params.where((p) => p.kind != CliParamKind.positional).toList();

  Map<String, dynamic> toJson() => {
    'route': route,
    if (module.isNotEmpty) 'module': module,
    if (description != null) 'description': description,
    'params': params.map((p) => p.toJson()).toList(),
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

  /// The contract for an exact route, or `null` if the route is not registered.
  CommandContract? forRoute(String route) {
    for (final contract in _contracts) {
      if (contract.route == route) return contract;
    }
    return null;
  }

  /// Every command registered under a module.
  List<CommandContract> forModule(String module) =>
      _contracts.where((c) => c.module == module).toList();

  bool get isEmpty => _contracts.isEmpty;
}
