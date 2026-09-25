import 'package:cli_router/cli_router.dart';

import 'cli_param.dart';
import 'cli_positional.dart';
import 'command_exception.dart';
import 'exit_codes.dart';

/// A rule spanning more than one option, checked once every option on the
/// invocation has been read and defaulted.
///
/// Operates over the set of option names that are actually *present* on the
/// invocation: an option a [DeclaredDefault] silently filled in does not
/// count as present, because the caller never wrote it.
abstract class CliConstraint {
  const CliConstraint();

  /// Returns a rejection message when [present] violates the rule, or
  /// `null` when it is satisfied.
  String? check(Set<String> present);

  Map<String, dynamic> toJson();
}

/// Exactly one of [fields] must be present: used for a command that only
/// makes sense given one mode, such as `--plan` or `--apply`.
class ExactlyOne extends CliConstraint {
  const ExactlyOne(this.fields);

  final List<String> fields;

  @override
  String? check(Set<String> present) {
    final given = fields.where(present.contains).toList();
    if (given.isEmpty) {
      return 'Choose one of: ${fields.map((f) => '--$f').join(', ')}';
    }
    if (given.length > 1) {
      return 'Choose one of: ${fields.map((f) => '--$f').join(', ')}, '
          'got ${given.map((f) => '--$f').join(', ')}';
    }
    return null;
  }

  @override
  Map<String, dynamic> toJson() => {'kind': 'exactlyOne', 'fields': fields};
}

/// At most one of [fields] may be present: used when two options each
/// stand on their own but cannot be combined.
class MutuallyExclusive extends CliConstraint {
  const MutuallyExclusive(this.fields);

  final List<String> fields;

  @override
  String? check(Set<String> present) {
    final given = fields.where(present.contains).toList();
    if (given.length > 1) {
      return '${fields.map((f) => '--$f').join(' and ')} cannot be combined, '
          'got ${given.map((f) => '--$f').join(', ')}';
    }
    return null;
  }

  @override
  Map<String, dynamic> toJson() => {
    'kind': 'mutuallyExclusive',
    'fields': fields,
  };
}

/// The full, declared shape of a command's or query's arguments: its
/// options, its positionals, and the cross-field rules that hold between
/// them.
///
/// This is the single source of truth `help` renders from and the SDK
/// enforces against: there is no undeclared escape hatch. A handler with
/// nothing to declare uses [CliContract.none] explicitly, rather than a
/// contract silently defaulting to empty.
class CliContract {
  const CliContract({
    this.options = const [],
    this.positionals = const [],
    this.constraints = const [],
  });

  /// A contract declaring no options, no positionals and no constraints.
  static const none = CliContract();

  final List<CliParam> options;
  final List<CliPositional> positionals;
  final List<CliConstraint> constraints;

  /// A copy with [extra] options appended: used to join a command's own
  /// declared options with ones the framework adds on its behalf (such as
  /// the plan/apply/autoapprove flags of [ChangeFlags]).
  CliContract withOptions(List<CliParam> extra) => CliContract(
    options: [...options, ...extra],
    positionals: positionals,
    constraints: constraints,
  );

  /// The shape `cli_router` enforces before a handler ever runs.
  List<OptionSpec> toOptionSpecs() =>
      options.map((o) => o.toOptionSpec()).toList();

  /// Validate [present] against every declared constraint, throwing the
  /// first violation found.
  void validateConstraints(Set<String> present) {
    for (final constraint in constraints) {
      final violation = constraint.check(present);
      if (violation != null) {
        throw CommandException(
          code: 'VALIDATION_FAILED',
          message: violation,
          exitCode: ExitCode.validationFailed,
        );
      }
    }
  }

  Map<String, dynamic> toJson() => {
    'options': options.map((o) => o.toJson()).toList(),
    'positionals': positionals.map((p) => p.toJson()).toList(),
    'constraints': constraints.map((c) => c.toJson()).toList(),
  };
}
