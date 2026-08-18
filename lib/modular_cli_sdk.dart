/// SDK for building modular CLIs with Dart.
///
/// Import `package:modular_cli_sdk/modular_cli_sdk.dart` to use:
/// - [ModularCli] — entry point that orchestrates modules and global flags
/// - [ModuleBuilder] — per-module route registration
/// - [Query] — a unit that reads and answers, and changes nothing
/// - [Command] — a unit that changes something, as an ordered list of steps
///   that say what they would do before anything runs
/// - [Input] / [Output] — typed DTOs for I/O
/// - [CliParam] — a route's declared parameter contract (help + enforcement)
/// - [CommandException] — structured error with code, message, and exit code
/// - [ExitCode] — semantic exit code constants
/// - [CliOutput] / [JsonCliOutput] / [TextCliOutput] — output formatting
/// - [Approver] / [PlanSink] — the two decisions a host keeps: how approval is
///   taken, and where a plan is filed
///
/// `Step`, `Preview`, `Outcome` and `Execution` come from
/// [preview_executor](https://pub.dev/packages/preview_executor) and are
/// re-exported here, so a command author imports one package.
///
/// **`PreviewExecutor` is deliberately not among them.** The engine publishes
/// it because the engine's consumer is a framework, and running steps is what
/// a framework does with it. This library's consumer is a command author, and
/// for them the same class is a way out of the arrangement: a command that
/// could reach the executor could run steps with no plan shown, no approval
/// taken, and no check that what happened is what was announced.
///
/// Narrowing the surface for a different audience is what this re-export is
/// for. Tests are the one place the executor is legitimately needed, and they
/// get it — along with the lifecycle already assembled — from
/// `package:modular_cli_sdk/testing.dart`.
library;

export 'package:preview_executor/preview_executor.dart'
    show
        Discrepancy,
        Execution,
        Outcome,
        Preview,
        Step,
        StepContext,
        StepFailure;

export 'src/approver.dart' show Approver, ConsoleApprover, NoApproverAvailable;
export 'src/change_flags.dart' show ChangeFlags, ChangeMode;
export 'src/change_outputs.dart'
    show DeclinedOutput, NothingToDoOutput, PlanOutput;
export 'src/cli_output.dart' show CliOutput;
export 'src/cli_output_json.dart' show JsonCliOutput;
export 'src/cli_output_text.dart' show TextCliOutput;
export 'src/cli_param.dart' show CliParam, CliParamKind, CliParamType;
export 'src/command.dart' show Command;
export 'src/command_catalog.dart'
    show CommandCatalog, CommandContract, CommandKind;
export 'src/command_exception.dart' show CommandException;
export 'src/exit_codes.dart' show ExitCode;
export 'src/explains_nothing_to_do.dart' show ExplainsNothingToDo;
export 'src/global_options.dart' show globalOptions;
export 'src/help_renderer.dart' show HelpRenderer;
export 'src/input.dart' show Input;
export 'src/modular_cli.dart' show ModularCli;
export 'src/module_builder.dart' show ModuleBuilder;
export 'src/output.dart' show Output;
export 'src/plan.dart' show PlanDocument, PlanSink;
export 'src/query.dart' show Query;
