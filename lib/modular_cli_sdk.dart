/// SDK for building modular CLIs with Dart.
///
/// Import `package:modular_cli_sdk/modular_cli_sdk.dart` to use:
/// - [ModularCli] — entry point that orchestrates modules and global flags
/// - [ModuleBuilder] — per-module route registration
/// - [Query] — a unit that reads and answers, and changes nothing
/// - [Command] — a unit that changes something, as an ordered list of steps
///   that say what they would do before anything runs
/// - [Input] / [Output] — typed DTOs for I/O
/// - [CliContract]: a route's declared contract, with [CliParam] options,
///   [CliPositional] positionals, and cross-field [CliConstraint]s
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
export 'src/cli_plugin.dart'
    show
        CliHostMetadata,
        CliPlugin,
        CliPluginError,
        CliPluginHost,
        CliPluginManifest,
        CommandFactory,
        QueryFactory,
        checkHostApiCompatibility,
        cliPluginHostApiVersion,
        orderCliPlugins;
export 'src/cli_plugin_host.dart' show RuntimeCliPluginHost;
export 'src/plugins/doctor_plugin.dart'
    show
        CliCheckResult,
        CliCheckStatus,
        CliDoctorCheck,
        CliDoctorEntry,
        DoctorInput,
        DoctorOutput,
        DoctorPlugin,
        DoctorQuery;
export 'src/plugins/installation/cli_downloader.dart'
    show CliDownloadFailure, CliDownloader, HttpCliDownloader;
export 'src/plugins/installation/cli_file_system.dart'
    show
        CliExecutableCheckFailure,
        CliExecutableChecker,
        CliFileSystem,
        IoCliExecutableChecker,
        IoCliFileSystem;
export 'src/plugins/installation/cli_platform.dart'
    show CliPlatform, IoCliPlatform;
export 'src/plugins/installation/cli_process_launcher.dart'
    show
        CliCleanupWorkerStartFailure,
        CliProcessLauncher,
        IoCliProcessLauncher,
        cleanupWorkerBootstrapScript,
        cleanupWorkerParentExitTimeoutMs,
        cleanupWorkerPayloadPathEnvVar,
        cleanupWorkerReadyMarkerPathEnvVar,
        cleanupWorkerStartupTimeout,
        cmdExecutablePath,
        powershellExecutablePath;
export 'src/plugins/installation/cli_release_source.dart'
    show
        CliRelease,
        CliReleaseAsset,
        CliReleaseLookupFailure,
        CliReleaseSource,
        HttpCliReleaseSource;
export 'src/plugins/installation/installation_plugin.dart'
    show
        CliInstallStepFailure,
        CliInstallationConfig,
        CliInvalidReleaseTag,
        DownloadAssetStep,
        InstallExecutableStep,
        InstallationPlugin,
        RemoveFileStep,
        SelfDeleteExecutableStep,
        UninstallCommand,
        UninstallInput,
        UninstallOutput,
        UpgradeCommand,
        UpgradeInput,
        UpgradeOutput,
        assetForPlatform,
        latestTaggedRelease;
export 'src/plugins/version_plugin.dart'
    show VersionInput, VersionOutput, VersionPlugin, VersionQuery;
export 'src/cli_output.dart' show CliOutput;
export 'src/cli_output_json.dart' show JsonCliOutput;
export 'src/cli_output_text.dart' show TextCliOutput;
export 'src/cli_contract.dart'
    show CliConstraint, CliContract, ExactlyOne, MutuallyExclusive;
export 'src/cli_param.dart' show CliParam, CliParamType, DeclaredDefault;
export 'src/cli_positional.dart' show CliPositional, CliPositionalType;
export 'src/cli_request_values.dart' show CliRequestValues;
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
export 'src/skips_interactive_approval.dart' show SkipsInteractiveApproval;
