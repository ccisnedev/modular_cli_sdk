import 'package:cli_router/cli_router.dart';

import 'cli_contract.dart';

/// Applies a command's declared contract to the invocation that arrived.
///
/// By the time this runs, `cli_router` has already rejected what it alone
/// can tell is wrong: an option nobody declared, a required option that
/// never showed up, an option repeated when it was not declared repeatable.
/// What is left is this SDK's own concern — the shape `cli_router` cannot
/// see: whether a value parses as the declared type, whether it is one of a
/// declared enumeration, whether a declared path exists, whether a declared
/// positional parses, and whether the options that *are* present satisfy
/// the contract's cross-field [CliConstraint]s. A declared but absent
/// [DeclaredDefault] is synthesized here, so a command reads it exactly as
/// if the caller had written it.
///
/// A contract is always supplied — [CliContract.none] for a command that
/// declares nothing — so there is no undeclared branch left to skip.
CliRequest applyDeclaredContract(CliRequest req, CliContract contract) {
  final resolvedOptions = <ParsedOption>[...req.options];
  final present = <String>{for (final o in req.options) o.spec.name};

  for (final param in contract.options) {
    final existing = _find(resolvedOptions, param.name);
    if (existing != null) {
      // Type, enumeration and path-existence checks; throws on failure.
      // Router already guaranteed presence/required/repeat-count.
      param.parse(existing.value ?? '');
      continue;
    }
    final declaredDefault = param.defaultValue;
    if (declaredDefault != null) {
      resolvedOptions.add(
        ParsedOption(
          spec: param.toOptionSpec(),
          written: '--${param.name}',
          argvIndex: -1,
          value: '${declaredDefault.value}',
          attached: false,
        ),
      );
    }
  }

  for (final positional in contract.positionals) {
    final rawValue = req.param(positional.name);
    if (rawValue != null) positional.parse(rawValue);
  }

  contract.validateConstraints(present);

  return CliRequest(
    originalArgs: req.originalArgs,
    route: req.route,
    params: req.params,
    rest: req.rest,
    options: resolvedOptions,
    stdout: req.stdout,
    stderr: req.stderr,
  );
}

ParsedOption? _find(List<ParsedOption> options, String name) {
  for (final option in options) {
    if (option.spec.name == name) return option;
  }
  return null;
}
