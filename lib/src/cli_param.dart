import 'command_exception.dart';
import 'exit_codes.dart';

/// How a parameter is written on the command line.
enum CliParamKind {
  /// `--count 3` / `--count=3` / `-c 3`.
  option,

  /// `--verbose` / `-v` / `--no-verbose`.
  flag,

  /// An ordered token embedded in the route: `show <id>`.
  positional,
}

/// The type a raw argument string is coerced into.
enum CliParamType { string, integer, number, boolean }

/// One declared parameter of a command.
///
/// The declaration is the single source of truth: the framework renders help
/// from it *and* enforces it at parse time, so help can never describe a
/// contract the command does not actually apply. For that reason a facet the
/// runtime cannot honour is not declarable: `cli_router` keeps flags in a map
/// keyed by name, so a repeated flag overwrites the previous one and there is
/// no repeatable parameter to describe.
///
/// ```dart
/// class AddInput extends Input {
///   static final params = [
///     CliParam.integer('a', abbr: 'a', required: true, description: 'First operand'),
///     CliParam.integer('b', abbr: 'b', required: true, description: 'Second operand'),
///   ];
/// }
/// ```
class CliParam {
  CliParam._({
    required this.name,
    required this.kind,
    required this.type,
    this.abbr,
    this.required = false,
    this.defaultValue,
    this.allowed,
    this.description,
  }) {
    if (required && defaultValue != null) {
      throw ArgumentError(
        'Parameter "$name" declares a default and is required: a default '
        'value can never apply.',
      );
    }
  }

  /// Long name, written `--name` on the command line.
  final String name;

  final CliParamKind kind;
  final CliParamType type;

  /// Short alias, written `-n`.
  final String? abbr;

  final bool required;

  /// Applied when the parameter is absent from the invocation.
  final Object? defaultValue;

  /// When set, any value outside this list is rejected.
  final List<String>? allowed;

  final String? description;

  /// An option carrying a value: `--count 3`.
  factory CliParam.string(
    String name, {
    String? abbr,
    bool required = false,
    String? defaultValue,
    List<String>? allowed,
    String? description,
  }) => CliParam._(
    name: name,
    kind: CliParamKind.option,
    type: CliParamType.string,
    abbr: abbr,
    required: required,
    defaultValue: defaultValue,
    allowed: allowed,
    description: description,
  );

  /// An option whose value is a whole number: `--count 3`.
  factory CliParam.integer(
    String name, {
    String? abbr,
    bool required = false,
    int? defaultValue,
    String? description,
  }) => CliParam._(
    name: name,
    kind: CliParamKind.option,
    type: CliParamType.integer,
    abbr: abbr,
    required: required,
    defaultValue: defaultValue,
    description: description,
  );

  /// An option whose value is a decimal number: `--ratio 1.5`.
  factory CliParam.number(
    String name, {
    String? abbr,
    bool required = false,
    double? defaultValue,
    String? description,
  }) => CliParam._(
    name: name,
    kind: CliParamKind.option,
    type: CliParamType.number,
    abbr: abbr,
    required: required,
    defaultValue: defaultValue,
    description: description,
  );

  /// A switch that needs no value: `--verbose`, `-v`, `--no-verbose`.
  factory CliParam.boolean(
    String name, {
    String? abbr,
    bool? defaultValue,
    String? description,
  }) => CliParam._(
    name: name,
    kind: CliParamKind.flag,
    type: CliParamType.boolean,
    abbr: abbr,
    defaultValue: defaultValue,
    description: description,
  );

  /// A route segment: `show <id>`. Always required — without it the route
  /// does not match at all.
  factory CliParam.positional(
    String name, {
    CliParamType type = CliParamType.string,
    List<String>? allowed,
    String? description,
  }) => CliParam._(
    name: name,
    kind: CliParamKind.positional,
    type: type,
    required: true,
    allowed: allowed,
    description: description,
  );

  /// Every name this parameter answers to besides [name].
  List<String> get aliases => abbr == null ? const [] : [abbr!];

  /// Coerce a raw command-line value into the declared type.
  ///
  /// Throws a [CommandException] with [ExitCode.validationFailed] when the
  /// value does not honour the declaration — the same failure the user sees.
  Object parse(String rawValue) {
    final value = _coerce(rawValue);
    if (value == null) {
      throw _rejected('expected $_typeLabel, got "$rawValue"');
    }
    final allowedValues = allowed;
    if (allowedValues != null && !allowedValues.contains(rawValue)) {
      throw _rejected('must be one of ${allowedValues.join(', ')}');
    }
    return value;
  }

  Object? _coerce(String rawValue) {
    switch (type) {
      case CliParamType.string:
        return rawValue;
      case CliParamType.integer:
        return int.tryParse(rawValue);
      case CliParamType.number:
        return double.tryParse(rawValue);
      case CliParamType.boolean:
        return _coerceBoolean(rawValue);
    }
  }

  /// A flag written bare (`--verbose`) reaches here with an empty value.
  bool? _coerceBoolean(String rawValue) {
    const truthy = {'', 'true', '1', 'yes', 'on'};
    const falsy = {'false', '0', 'no', 'off'};
    final value = rawValue.toLowerCase();
    if (truthy.contains(value)) return true;
    if (falsy.contains(value)) return false;
    return null;
  }

  String get _typeLabel => switch (type) {
    CliParamType.string => 'a string',
    CliParamType.integer => 'an integer',
    CliParamType.number => 'a number',
    CliParamType.boolean => 'a boolean',
  };

  CommandException _rejected(String reason) => CommandException(
    code: 'VALIDATION_FAILED',
    message: '$_invocationName: $reason',
    exitCode: ExitCode.validationFailed,
    details: {'parameter': name},
  );

  /// How the parameter is written when reported back to the user.
  String get _invocationName =>
      kind == CliParamKind.positional ? '<$name>' : '--$name';

  /// The contract as `help --json` publishes it.
  Map<String, dynamic> toJson() => {
    'name': name,
    'kind': kind.name,
    'type': type.name,
    'aliases': aliases,
    'required': required,
    if (defaultValue != null) 'default': defaultValue,
    if (allowed != null) 'allowed': allowed,
    if (description != null) 'description': description,
  };
}
