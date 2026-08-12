/// Drives a [Command] the way the framework drives it, for tests that hold one
/// command rather than a whole [ModularCli].
///
/// ```dart
/// import 'package:modular_cli_sdk/testing.dart';
///
/// test('opens the requisition', () async {
///   final output = await applyCommand(OpenRequisition(input));
///   expect(output.dir, 'docs/requisitions/20260812-billing');
/// });
/// ```
///
/// **Why this is a separate library.** A command is built from steps, and
/// something else previews or performs them — in production, always the
/// framework. `PreviewExecutor` is therefore not exported by
/// `modular_cli_sdk.dart`: a command that could reach it could run steps
/// outside the gate, with no plan shown, no approval taken and no check that
/// what happened is what was announced, which is the one thing the whole
/// arrangement exists to prevent.
///
/// Tests need what production must not have. Putting it here rather than in the
/// main library is what lets both be true: production code imports
/// `modular_cli_sdk.dart` and cannot reach the executor; a test imports this and
/// gets a lifecycle it did not have to reimplement.
///
/// **And reimplementing it is the real hazard.** These three functions do what
/// `ModuleBuilder` does and nothing more. A host that hand-rolled them instead
/// would hold a second description of the same lifecycle, with nothing keeping
/// the two in agreement — so the day the framework changes, that host's suite
/// stays green while testing a flow the CLI no longer takes. That is the
/// `dryRun` flag all over again, in the test suite.
library;

import 'package:preview_executor/preview_executor.dart';

import 'src/command.dart';
import 'src/input.dart';
import 'src/output.dart';

export 'package:preview_executor/preview_executor.dart' show PreviewExecutor;

/// What [command] says it would do. Nothing is performed.
///
/// This is `--plan`, minus the rendering and the plan file — both of which
/// belong to the framework and are tested there.
Future<List<Preview>> previewCommand<I extends Input, O extends Output>(
  Command<I, O> command,
) async => const PreviewExecutor().preview(await command.steps());

/// Performs [command]'s steps in order and returns the run — including whether
/// every step did what it had said it would.
///
/// This is `--apply --autoapprove`. Approval belongs to the framework, and a
/// test that wants to exercise the asking should drive a whole [ModularCli]
/// with an `Approver`; that is the right way to test approval, and the wrong
/// way to test a command.
Future<Execution> runCommand<I extends Input, O extends Output>(
  Command<I, O> command,
) async => const PreviewExecutor().perform(await command.steps());

/// Performs [command] and returns the `Output` it describes.
///
/// The shape most tests want. Returns `O`, not `Output`, so a test can assert
/// on the command's own fields without casting first.
///
/// [Command.describe] is called even when the run stopped early, exactly as the
/// framework calls it, so a test can assert what a half-finished command
/// reports.
Future<O> applyCommand<I extends Input, O extends Output>(
  Command<I, O> command,
) async => command.describe(await runCommand(command));
