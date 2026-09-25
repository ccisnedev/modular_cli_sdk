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

  // A constraint (spec's `ExactlyOne`/`MutuallyExclusive`) is checked over
  // every field the caller actually chose — and a bound positional is
  // exactly as much a choice as a `--flag` is: `eval rpn '1 2 +'` chose
  // `program` precisely as deliberately as `eval rpn --stdin '1 2 +'`
  // chose `stdin`. Leaving positionals out of `present` made a constraint
  // spanning a positional and an option unsatisfiable through the
  // positional side alone.
  final present = <String>{
    for (final o in req.options) o.spec.name,
    for (final p in contract.positionals)
      if (req.param(p.name) != null) p.name,
  };

  for (final param in contract.options) {
    // A repeatable option can occur more than once on the invocation —
    // `cli_router` allows every occurrence through once it has confirmed
    // the option itself is declared repeatable, but it does not know this
    // SDK's own type/enum/path rules, so every occurrence, not just the
    // first, must be checked against them: `repeat --count 1 --count bad`
    // is only caught by validating the second occurrence too.
    final occurrences = _findAll(resolvedOptions, param.name);
    if (occurrences.isNotEmpty) {
      for (final occurrence in occurrences) {
        // Type, enumeration and path-existence checks; throws on failure.
        // Router already guaranteed presence/required/repeat-count.
        param.parse(occurrence.value ?? '');
      }
      continue;
    }
    final declaredDefault = param.defaultValue;
    if (declaredDefault != null) {
      final rawValue = '${declaredDefault.value}';
      // A declared default must satisfy the same declaration it is a
      // default *for*: an enum default outside its own `values` is already
      // rejected at registration (`CliParam`'s constructor), but a
      // `mustExist` path default can only be checked against the
      // filesystem as it stands right now — so it is validated here, the
      // same way a value the caller actually typed would be, rather than
      // trusted unchecked because nobody typed it.
      param.parse(rawValue);
      resolvedOptions.add(
        ParsedOption(
          spec: param.toOptionSpec(),
          written: '--${param.name}',
          argvIndex: -1,
          value: rawValue,
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

List<ParsedOption> _findAll(List<ParsedOption> options, String name) => [
  for (final option in options)
    if (option.spec.name == name) option,
];
