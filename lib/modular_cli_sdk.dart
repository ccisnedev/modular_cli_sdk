/// SDK for building modular CLIs with Dart.
///
/// Import `package:modular_cli_sdk/modular_cli_sdk.dart` to use:
/// - [ModularCli] — entry point that orchestrates modules and global flags
/// - [ModuleBuilder] — per-module command registration
/// - [Command] — abstract unit of work (input → validate → execute → output)
/// - [Input] / [Output] — typed DTOs for command I/O
/// - [CommandException] — structured error with code, message, and exit code
/// - [ExitCode] — semantic exit code constants
/// - [CliOutput] / [JsonCliOutput] / [TextCliOutput] — output formatting
library;

export 'src/cli_output.dart' show CliOutput;
export 'src/cli_output_json.dart' show JsonCliOutput;
export 'src/cli_output_text.dart' show TextCliOutput;
export 'src/command.dart' show Command;
export 'src/command_exception.dart' show CommandException;
export 'src/exit_codes.dart' show ExitCode;
export 'src/input.dart' show Input;
export 'src/modular_cli.dart' show ModularCli;
export 'src/module_builder.dart' show ModuleBuilder;
export 'src/output.dart' show Output;
