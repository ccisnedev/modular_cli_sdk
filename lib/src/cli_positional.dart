import 'command_exception.dart';
import 'exit_codes.dart';

/// The type a positional argument's raw text is coerced into.
enum CliPositionalType {
  /// `touch a.txt`.
  string,

  /// `retry 3`.
  integer,

  /// `scale 1.5`.
  number,
}

/// One declared **positional** argument of a command — a word read by its
/// place in the invocation rather than by a `--name`.
///
/// Kept as its own type, distinct from [CliParam], because a positional has
/// no `--name`, no abbreviation and no repeatability: it is a fixed slot in
/// the route pattern itself (`cli_router`'s `<param>` segment), not a
/// scanned option. Folding it into [CliParam] would leave most of that
/// type's fields meaningless for every positional value.
class CliPositional {
  CliPositional._({
    required this.name,
    required this.type,
    required this.required,
    this.values,
    this.description,
  }) {
    if (type == CliPositionalType.string && values != null && values!.isEmpty) {
      throw ArgumentError(
        'Positional "$name" declares an empty allow-list; omit "values" to '
        'accept any string.',
      );
    }
  }

  /// The name the route pattern binds it under, e.g. `<name>`.
  final String name;

  final CliPositionalType type;

  /// Whether this positional must be present. Must agree with the route
  /// pattern it is declared against: `true` for a required `<name>`
  /// segment, `false` for a trailing optional `[<name>]` segment — checked
  /// at registration, not left to be discovered at runtime.
  final bool required;

  /// When set, the closed list of strings this positional accepts.
  /// Only meaningful for [CliPositionalType.string].
  final List<String>? values;

  final String? description;

  factory CliPositional.string(
    String name, {
    required bool required,
    List<String>? values,
    String? description,
  }) => CliPositional._(
    name: name,
    type: CliPositionalType.string,
    required: required,
    values: values,
    description: description,
  );

  factory CliPositional.integer(
    String name, {
    required bool required,
    String? description,
  }) => CliPositional._(
    name: name,
    type: CliPositionalType.integer,
    required: required,
    description: description,
  );

  factory CliPositional.number(
    String name, {
    required bool required,
    String? description,
  }) => CliPositional._(
    name: name,
    type: CliPositionalType.number,
    required: required,
    description: description,
  );

  /// Coerce the raw word `cli_router` bound to [name] into the declared
  /// type.
  Object parse(String rawValue) {
    final value = _coerce(rawValue);
    if (value == null) {
      throw _rejected('expected $_typeLabel, got "$rawValue"');
    }
    if (values != null && !values!.contains(rawValue)) {
      throw _rejected('must be one of ${values!.join(', ')}');
    }
    return value;
  }

  Object? _coerce(String rawValue) {
    switch (type) {
      case CliPositionalType.string:
        return rawValue;
      case CliPositionalType.integer:
        return int.tryParse(rawValue);
      case CliPositionalType.number:
        return double.tryParse(rawValue);
    }
  }

  String get _typeLabel => switch (type) {
    CliPositionalType.string => 'a string',
    CliPositionalType.integer => 'an integer',
    CliPositionalType.number => 'a number',
  };

  CommandException _rejected(String reason) => CommandException(
    code: 'VALIDATION_FAILED',
    message: '<$name>: $reason',
    exitCode: ExitCode.validationFailed,
    details: {'parameter': name},
  );

  Map<String, dynamic> toJson() => {
    'name': name,
    'kind': 'positional',
    'type': type.name,
    'required': required,
    if (values != null) 'allowed': values,
    if (description != null) 'description': description,
  };
}
