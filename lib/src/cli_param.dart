import 'dart:io' as io;

import 'package:cli_router/cli_router.dart';

import 'command_exception.dart';
import 'exit_codes.dart';

/// The type a raw option value is coerced into.
enum CliParamType {
  /// `--verbose` / `-v`. Carries no value.
  flag,

  /// `--name value`.
  string,

  /// `--count 3`.
  integer,

  /// `--ratio 1.5`.
  number,

  /// `--format text`, restricted to [CliParam.values].
  enumeration,

  /// `--config file.yaml`, optionally required to exist ([CliParam.mustExist]).
  path,
}

/// A declared fallback value, applied when the option is absent.
///
/// Wrapped rather than a bare value so a default is never silent: [reason]
/// says why the default is what it is, and that reason is what help renders
/// alongside it. "default: World" on its own answers nothing a caller could
/// not already see from the flag being optional.
class DeclaredDefault<T extends Object> {
  const DeclaredDefault(this.value, {required this.reason});

  final T value;
  final String reason;

  @override
  String toString() => '$value';
}

/// One declared **option** of a command: never a positional; see
/// [CliPositional] for that.
///
/// The declaration is the single source of truth: the framework renders help
/// from it *and* enforces it at parse time, so help can never describe a
/// contract the command does not actually apply.
///
/// Every field that changes behavior is required and named, mirroring
/// `cli_router`'s own [OptionSpec]: there is no default shape an option
/// falls back on. A flag is never `required` (there is nothing to be
/// "missing"; either it was read or not).
///
/// ```dart
/// class AddInput extends Input {
///   static final options = [
///     CliParam.integer('a', abbr: 'a', required: true, repeatable: false,
///         description: 'First operand'),
///     CliParam.integer('b', abbr: 'b', required: true, repeatable: false,
///         description: 'Second operand'),
///   ];
/// }
/// ```
class CliParam {
  CliParam._({
    required this.name,
    required this.type,
    this.abbr,
    required this.required,
    required this.repeatable,
    this.defaultValue,
    this.values,
    this.mustExist,
    this.description,
  }) {
    if (required && defaultValue != null) {
      throw ArgumentError(
        'Parameter "$name" declares a default and is required: a default '
        'value can never apply.',
      );
    }
    if (type == CliParamType.enumeration &&
        (values == null || values!.isEmpty)) {
      throw ArgumentError(
        'Parameter "$name" is an enumeration and must declare its values.',
      );
    }
    final default_ = defaultValue;
    if (type == CliParamType.enumeration &&
        default_ != null &&
        !values!.contains(default_.value)) {
      throw ArgumentError(
        'Parameter "$name" declares a default of "${default_.value}", '
        'which is not one of its own allowed values: '
        '${values!.join(', ')}.',
      );
    }
  }

  /// Long name, written `--name` on the command line.
  final String name;

  final CliParamType type;

  /// Short alias, written `-n`.
  final String? abbr;

  /// Whether the route cannot resolve without this option. Always `false`
  /// for a flag.
  final bool required;

  /// Whether the option may occur more than once on the same invocation.
  final bool repeatable;

  /// Applied when the option is absent from the invocation.
  final DeclaredDefault<Object>? defaultValue;

  /// The closed set of values a [CliParamType.enumeration] accepts.
  final List<String>? values;

  /// For [CliParamType.path]: whether the path must exist on disk to be
  /// accepted. Required precisely because there is no sensible default for
  /// it: a path option that does not say either way would silently accept
  /// paths nobody checked.
  final bool? mustExist;

  final String? description;

  /// A switch that needs no value: `--verbose`, `-v`.
  factory CliParam.flag(
    String name, {
    String? abbr,
    required bool repeatable,
    String? description,
  }) => CliParam._(
    name: name,
    type: CliParamType.flag,
    abbr: abbr,
    required: false,
    repeatable: repeatable,
    description: description,
  );

  /// An option carrying a string value: `--name value`.
  factory CliParam.string(
    String name, {
    String? abbr,
    required bool required,
    required bool repeatable,
    DeclaredDefault<String>? defaultValue,
    String? description,
  }) => CliParam._(
    name: name,
    type: CliParamType.string,
    abbr: abbr,
    required: required,
    repeatable: repeatable,
    defaultValue: defaultValue,
    description: description,
  );

  /// An option whose value is a whole number: `--count 3`.
  factory CliParam.integer(
    String name, {
    String? abbr,
    required bool required,
    required bool repeatable,
    DeclaredDefault<int>? defaultValue,
    String? description,
  }) => CliParam._(
    name: name,
    type: CliParamType.integer,
    abbr: abbr,
    required: required,
    repeatable: repeatable,
    defaultValue: defaultValue,
    description: description,
  );

  /// An option whose value is a decimal number: `--ratio 1.5`.
  factory CliParam.number(
    String name, {
    String? abbr,
    required bool required,
    required bool repeatable,
    DeclaredDefault<double>? defaultValue,
    String? description,
  }) => CliParam._(
    name: name,
    type: CliParamType.number,
    abbr: abbr,
    required: required,
    repeatable: repeatable,
    defaultValue: defaultValue,
    description: description,
  );

  /// An option restricted to a closed set of values: `--format text`.
  factory CliParam.enumeration(
    String name, {
    String? abbr,
    required bool required,
    required bool repeatable,
    required List<String> values,
    DeclaredDefault<String>? defaultValue,
    String? description,
  }) => CliParam._(
    name: name,
    type: CliParamType.enumeration,
    abbr: abbr,
    required: required,
    repeatable: repeatable,
    defaultValue: defaultValue,
    values: values,
    description: description,
  );

  /// An option whose value names a filesystem path: `--config file.yaml`.
  ///
  /// [mustExist] is required, not defaulted: whether a missing path is this
  /// option's problem or the command's is a fact about the option, and no
  /// answer is the safe one to assume silently.
  factory CliParam.path(
    String name, {
    String? abbr,
    required bool required,
    required bool repeatable,
    required bool mustExist,
    DeclaredDefault<String>? defaultValue,
    String? description,
  }) => CliParam._(
    name: name,
    type: CliParamType.path,
    abbr: abbr,
    required: required,
    repeatable: repeatable,
    defaultValue: defaultValue,
    mustExist: mustExist,
    description: description,
  );

  bool get isFlag => type == CliParamType.flag;

  /// Every name this option answers to besides [name].
  List<String> get aliases => abbr == null ? const [] : [abbr!];

  /// The shape `cli_router` enforces before this option ever reaches the
  /// command: which flags exist, which are required, which repeat. Type,
  /// enumeration membership and path existence are this SDK's own concern
  /// (`cli_router` knows nothing about them) and are checked by [parse].
  OptionSpec toOptionSpec() => isFlag
      ? OptionSpec.flag(name, abbr: abbr, repeatable: repeatable)
      : OptionSpec.value(
          name,
          abbr: abbr,
          required: required,
          repeatable: repeatable,
        );

  /// Coerce a raw command-line value into the declared type.
  ///
  /// Throws a [CommandException] with [ExitCode.validationFailed] when the
  /// value does not honour the declaration — the same failure the user sees.
  Object parse(String rawValue) {
    final value = _coerce(rawValue);
    if (value == null) {
      throw _rejected('expected $_typeLabel, got "$rawValue"');
    }
    if (type == CliParamType.enumeration && !values!.contains(rawValue)) {
      throw _rejected('must be one of ${values!.join(', ')}');
    }
    if (type == CliParamType.path && mustExist! && !_existsOnDisk(rawValue)) {
      throw _rejected('no such file or directory');
    }
    return value;
  }

  Object? _coerce(String rawValue) {
    switch (type) {
      case CliParamType.flag:
        return true;
      case CliParamType.string:
      case CliParamType.enumeration:
      case CliParamType.path:
        return rawValue;
      case CliParamType.integer:
        return int.tryParse(rawValue);
      case CliParamType.number:
        return double.tryParse(rawValue);
    }
  }

  bool _existsOnDisk(String rawValue) =>
      io.FileSystemEntity.typeSync(rawValue) !=
      io.FileSystemEntityType.notFound;

  String get _typeLabel => switch (type) {
    CliParamType.flag => 'nothing',
    CliParamType.string => 'a string',
    CliParamType.integer => 'an integer',
    CliParamType.number => 'a number',
    CliParamType.enumeration => 'one of ${values!.join(', ')}',
    CliParamType.path => 'a path',
  };

  CommandException _rejected(String reason) => CommandException(
    code: 'VALIDATION_FAILED',
    message: '--$name: $reason',
    exitCode: ExitCode.validationFailed,
    details: {'parameter': name},
  );

  /// The contract as `help --json` publishes it.
  Map<String, dynamic> toJson() => {
    'name': name,
    'kind': 'option',
    'type': type.name,
    'aliases': aliases,
    'required': required,
    'repeatable': repeatable,
    if (defaultValue != null) 'default': defaultValue!.value,
    if (defaultValue != null) 'defaultReason': defaultValue!.reason,
    if (values != null) 'allowed': values,
    if (mustExist != null) 'mustExist': mustExist,
    if (description != null) 'description': description,
  };
}
