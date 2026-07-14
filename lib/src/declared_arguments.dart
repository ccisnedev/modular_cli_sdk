import 'package:cli_router/cli_router.dart';

import 'cli_param.dart';
import 'command_exception.dart';
import 'exit_codes.dart';
import 'global_options.dart';

/// Applies a command's declared contract to the invocation that arrived.
///
/// Declaring is parsing: the same [CliParam] list that help renders is the one
/// that resolves abbreviations, applies defaults, coerces types, and rejects
/// what the command never declared. The request handed to the command's Input
/// factory is therefore already the contract, not the raw command line.
///
/// A command that declares **nothing** (`params` omitted, i.e. null) is returned
/// untouched — it keeps parsing its arguments imperatively, as before.
///
/// Declaring an **empty** contract (`params: const []`) is a different statement
/// and is enforced: the command accepts no option at all, so any option is an
/// error. The two were once the same value, which left the commands that take no
/// arguments — exactly the ones most likely to be mis-invoked — unchecked.
CliRequest applyDeclaredContract(CliRequest req, List<CliParam>? params) {
  if (params == null) return req;

  _rejectUndeclaredFlags(req.flags.keys, params);

  final resolvedFlags = <String, String?>{
    for (final entry in req.flags.entries)
      if (globalOptionNames.contains(entry.key)) entry.key: entry.value,
  };

  for (final param in params) {
    if (param.kind == CliParamKind.positional) {
      _validatePositional(req, param);
      continue;
    }
    final rawValue = _rawValueOf(req, param);
    if (rawValue == null) {
      _applyAbsence(resolvedFlags, param);
      continue;
    }
    param.parse(rawValue);
    resolvedFlags[param.name] = rawValue;
  }

  return CliRequest(
    originalArgs: req.originalArgs,
    matchedCommand: req.matchedCommand,
    params: req.params,
    flags: resolvedFlags,
    positionals: req.positionals,
    stdout: req.stdout,
    stderr: req.stderr,
  );
}

/// A flag nobody declared is a mistake the user wants to hear about, not a
/// value to ignore.
void _rejectUndeclaredFlags(Iterable<String> flagNames, List<CliParam> params) {
  final declared = <String>{
    for (final param in params) ...[param.name, ...param.aliases],
  };
  for (final flagName in flagNames) {
    if (declared.contains(flagName) || globalOptionNames.contains(flagName)) {
      continue;
    }
    throw CommandException(
      code: 'VALIDATION_FAILED',
      message: 'unknown option --$flagName',
      exitCode: ExitCode.validationFailed,
      details: {'parameter': flagName},
    );
  }
}

/// The value as written, under the long name or under the abbreviation.
String? _rawValueOf(CliRequest req, CliParam param) {
  for (final name in [param.name, ...param.aliases]) {
    if (req.flags.containsKey(name)) return req.flags[name] ?? '';
  }
  return null;
}

void _applyAbsence(Map<String, String?> resolvedFlags, CliParam param) {
  if (param.required) {
    throw CommandException(
      code: 'VALIDATION_FAILED',
      message: 'missing required option --${param.name}',
      exitCode: ExitCode.validationFailed,
      details: {'parameter': param.name},
    );
  }
  final declaredDefault = param.defaultValue;
  if (declaredDefault != null) {
    resolvedFlags[param.name] = '$declaredDefault';
  }
}

/// The route matched, so the positional is present; only its type and its
/// allowed values are still open questions.
void _validatePositional(CliRequest req, CliParam param) {
  final rawValue = req.param(param.name);
  if (rawValue == null) return;
  param.parse(rawValue);
}
