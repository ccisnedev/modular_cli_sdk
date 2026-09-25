import 'dart:convert';
import 'dart:io' as io;

/// Thrown when the detached PowerShell cleanup worker
/// [CliProcessLauncher.startCleanupWorker] launches could not be started at
/// all, or did not confirm it was ready (by creating its ready-marker file)
/// within [cleanupWorkerStartupTimeout]. Either way, nothing has been
/// scheduled for deletion, and the caller must not report otherwise.
class CliCleanupWorkerStartFailure implements Exception {
  const CliCleanupWorkerStartFailure(this.message);

  final String message;

  @override
  String toString() => message;
}

/// How long [CliProcessLauncher.startCleanupWorker] waits for the worker it
/// launches to create its ready-marker file before giving up and throwing
/// [CliCleanupWorkerStartFailure]. The worker creates that file only after it
/// has already parsed its payload and retained a handle to the parent
/// process, so a marker within this window means the worker genuinely holds
/// what it needs to finish the job unattended later.
const Duration cleanupWorkerStartupTimeout = Duration(seconds: 10);

/// How long, in milliseconds, the cleanup worker itself waits for the parent
/// process (the CLI that launched it) to exit before giving up and deleting
/// nothing. Milliseconds because that is the unit PowerShell's
/// `Process.WaitForExit(Int32)` takes. Five minutes: long enough to cover a
/// slow shutdown, bounded so a parent that never exits does not leave a
/// worker running forever either.
const int cleanupWorkerParentExitTimeoutMs = 5 * 60 * 1000;

/// The environment variable the cleanup worker reads its JSON payload file's
/// path from. Passed as an environment variable, not a command-line
/// argument: the worker is launched through `cmd.exe`'s `start`, and a path
/// on that command line would be re-parsed by `cmd.exe`'s own shell grammar
/// (`%`, `&`, `^`, quotes) on top of ordinary argv quoting. An environment
/// variable is inherited by the child untouched, with no second parsing
/// pass.
const String cleanupWorkerPayloadPathEnvVar = 'CLI_CLEANUP_PAYLOAD_PATH';

/// The environment variable the cleanup worker reads its ready-marker file's
/// path from. See [cleanupWorkerPayloadPathEnvVar] for why this travels as
/// an environment variable rather than a command-line argument.
const String cleanupWorkerReadyMarkerPathEnvVar = 'CLI_CLEANUP_READY_PATH';

/// The cleanup worker's bootstrap script, fixed and never interpolated:
/// every piece of run-specific data (which process to wait for, which paths
/// to delete, how long to wait) travels through the JSON file named by
/// [cleanupWorkerPayloadPathEnvVar], read once with `ConvertFrom-Json`.
/// Interpolating a path into a script string is exactly the failure mode
/// this replaces (a path containing `%`, `&`, `!`, quotes or parentheses
/// breaking, or escaping into, the parsing of whatever launched the script);
/// reading it as a JSON string value has none of that risk.
///
/// Sequence: read the payload file, retain a handle on the parent process
/// (if it is still running; a parent that has already exited by the time the
/// worker starts is treated as already gone rather than an error), create
/// the ready-marker file, wait up to the given timeout for the parent to
/// exit, and only on a confirmed exit delete each given path with
/// `Remove-Item -LiteralPath` under `$ErrorActionPreference = 'Stop'`. A
/// timed-out wait deletes nothing. The worker removes its own payload and
/// ready-marker files on the way out, whatever happened.
const String cleanupWorkerBootstrapScript = r'''
$ErrorActionPreference = 'Stop'
$PayloadPath = $env:CLI_CLEANUP_PAYLOAD_PATH
$ReadyMarkerPath = $env:CLI_CLEANUP_READY_PATH
try {
    $data = Get-Content -LiteralPath $PayloadPath -Raw | ConvertFrom-Json
    $parentPid = [int]$data.parentPid
    $paths = @($data.paths)
    $timeoutMs = [int]$data.timeoutMs

    $parent = $null
    try {
        $parent = [System.Diagnostics.Process]::GetProcessById($parentPid)
        $null = $parent.Handle
    } catch {
        $parent = $null
    }

    New-Item -ItemType File -Path $ReadyMarkerPath -Force | Out-Null

    $exited = $true
    if ($null -ne $parent) {
        $exited = $parent.WaitForExit($timeoutMs)
    }

    if ($exited) {
        foreach ($path in $paths) {
            Remove-Item -LiteralPath $path
        }
    }
} finally {
    Remove-Item -LiteralPath $PayloadPath -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $ReadyMarkerPath -ErrorAction SilentlyContinue
}
''';

/// Resolves the real Windows PowerShell executable's fixed path from
/// [environment]'s `SystemRoot` entry, the way [IoCliProcessLauncher] does
/// before launching the cleanup worker. Throws
/// [CliCleanupWorkerStartFailure] when `SystemRoot` is absent or empty,
/// rather than falling back to a bare `powershell.exe` that would run
/// whichever executable happens to be first on `PATH`, or an unqualified
/// `powershell` that a hijacked `PATH` could point anywhere.
String powershellExecutablePath(Map<String, String> environment) {
  final systemRoot = environment['SystemRoot'];
  if (systemRoot == null || systemRoot.isEmpty) {
    throw const CliCleanupWorkerStartFailure(
      'Could not start the cleanup worker: the SystemRoot environment '
      'variable is not set.',
    );
  }
  return '$systemRoot\\System32\\WindowsPowerShell\\v1.0\\powershell.exe';
}

/// Resolves the real `cmd.exe`'s fixed path from [environment]'s
/// `SystemRoot` entry, for the same reason [powershellExecutablePath]
/// resolves PowerShell's: never a bare `cmd.exe`/`cmd` that trusts `PATH`.
String cmdExecutablePath(Map<String, String> environment) {
  final systemRoot = environment['SystemRoot'];
  if (systemRoot == null || systemRoot.isEmpty) {
    throw const CliCleanupWorkerStartFailure(
      'Could not start the cleanup worker: the SystemRoot environment '
      'variable is not set.',
    );
  }
  return '$systemRoot\\System32\\cmd.exe';
}

/// The process identity and cleanup-worker-launching capability
/// [SelfDeleteExecutableStep] needs to remove a running Windows executable.
/// Injectable for the same reason [CliFileSystem] is: a test supplies a fake
/// that records what was launched, in place of actually launching a real
/// PowerShell worker and waiting on a real PID.
abstract class CliProcessLauncher {
  /// This process's own process id.
  int get currentPid;

  /// Starts the detached PowerShell cleanup worker, writes [payload] to a
  /// temporary JSON file for it to read, and waits for it to confirm
  /// readiness (its ready-marker file existing) within
  /// [cleanupWorkerStartupTimeout].
  ///
  /// [payload] carries `parentPid` (the process the worker waits on),
  /// `paths` (what it deletes once that process exits) and `timeoutMs` (how
  /// long it waits before giving up). It is written as-is, as JSON: no part
  /// of it is interpolated into a script or a command line, so nothing in
  /// it needs shell escaping.
  ///
  /// Throws [CliCleanupWorkerStartFailure] when the worker cannot be started
  /// at all, or does not confirm readiness in time. A worker that starts,
  /// confirms readiness, and then fails on its own later (after this process
  /// has already exited, with nobody left to observe it) is not this
  /// method's concern.
  Future<void> startCleanupWorker(Map<String, Object?> payload);
}

/// Launches a real, detached PowerShell cleanup worker.
///
/// Neither `ProcessStartMode.detached` nor `ProcessStartMode.detachedWithStdio`
/// can be used to launch PowerShell directly: both ask Windows to create the
/// process with no console at all (`DETACHED_PROCESS`), and Windows
/// PowerShell's own console host does not tolerate that: the process exits
/// within milliseconds, before running anything, confirmed by launching it
/// that way and observing that no process with the reported pid ever exists
/// long enough for `Get-Process` to find it, not even immediately after
/// spawn. `ProcessStartMode.normal` keeps a working console and delivers
/// I/O correctly, but ties the child to this process's Windows Job Object:
/// the child is killed the instant this process exits, which is exactly the
/// moment the cleanup worker needs to survive.
///
/// The fix used here is the standard Windows trick for breaking a process
/// out of its launcher's job object: launch it through `cmd.exe`'s `start`
/// built-in (`cmd /d /c start "" /min <powershell> ...`) under
/// `ProcessStartMode.normal`. `start` hands the new process off outside the
/// calling `cmd.exe`'s own process tree, so it is not part of this
/// process's job and survives this process exiting: confirmed empirically,
/// a target file persists while the launching process is alive and is
/// deleted within seconds of that process exiting, including when the
/// launching process exits within milliseconds of starting the worker, the
/// way a real CLI run does.
///
/// The worker's payload and ready-marker file paths travel as environment
/// variables ([cleanupWorkerPayloadPathEnvVar],
/// [cleanupWorkerReadyMarkerPathEnvVar]), not command-line arguments: the
/// `cmd.exe` command line here carries only fixed literal tokens plus the
/// PowerShell and script paths this class resolves and writes itself, never
/// the paths [startCleanupWorker]'s caller wants deleted. Those travel only
/// inside the payload JSON file, read by the script with `Get-Content` and
/// `ConvertFrom-Json`, never through any shell's parsing.
class IoCliProcessLauncher implements CliProcessLauncher {
  const IoCliProcessLauncher();

  @override
  int get currentPid => io.pid;

  @override
  Future<void> startCleanupWorker(Map<String, Object?> payload) async {
    final environment = io.Platform.environment;
    final powershellPath = powershellExecutablePath(environment);
    final cmdPath = cmdExecutablePath(environment);

    final tempDir = io.Directory.systemTemp;
    final token =
        '${io.pid}_${DateTime.now().microsecondsSinceEpoch}';
    final scriptPath =
        '${tempDir.path}${io.Platform.pathSeparator}cli_cleanup_worker_'
        '$token.ps1';
    final payloadPath =
        '${tempDir.path}${io.Platform.pathSeparator}cli_cleanup_payload_'
        '$token.json';
    final readyMarkerPath =
        '${tempDir.path}${io.Platform.pathSeparator}cli_cleanup_ready_'
        '$token.marker';

    try {
      io.File(scriptPath).writeAsStringSync(cleanupWorkerBootstrapScript);
      io.File(payloadPath).writeAsStringSync(jsonEncode(payload));
    } on Object catch (e) {
      throw CliCleanupWorkerStartFailure(
        'Could not start the cleanup worker: could not write its temporary '
        'files: $e',
      );
    }

    final workerEnvironment = Map<String, String>.from(environment)
      ..[cleanupWorkerPayloadPathEnvVar] = payloadPath
      ..[cleanupWorkerReadyMarkerPathEnvVar] = readyMarkerPath;

    // Deliberately Process.start, awaiting only exitCode, never
    // stdout/stderr: cmd.exe's `start` hands the worker off to a process
    // outside cmd.exe's own tree, but that worker can still inherit cmd.exe's
    // stdout/stderr pipe handles. Process.run would wait for those pipes to
    // see end-of-file, which does not happen until the long-lived worker
    // itself exits, minutes later. Only the launcher's own exit code is
    // this call's concern.
    final io.Process launcher;
    try {
      launcher = await io.Process.start(
        cmdPath,
        [
          '/d',
          '/c',
          'start',
          '""',
          '/min',
          powershellPath,
          '-NoProfile',
          '-NonInteractive',
          '-File',
          scriptPath,
        ],
        runInShell: false,
        environment: workerEnvironment,
        mode: io.ProcessStartMode.normal,
      );
    } on Object catch (e) {
      throw CliCleanupWorkerStartFailure(
        'Could not start the cleanup worker at $powershellPath: $e',
      );
    }
    final launchExitCode = await launcher.exitCode;
    if (launchExitCode != 0) {
      throw CliCleanupWorkerStartFailure(
        'Could not start the cleanup worker: $cmdPath exited with code '
        '$launchExitCode.',
      );
    }

    final deadline = DateTime.now().add(cleanupWorkerStartupTimeout);
    while (!io.File(readyMarkerPath).existsSync()) {
      if (DateTime.now().isAfter(deadline)) {
        throw CliCleanupWorkerStartFailure(
          'The cleanup worker did not confirm it was ready within '
          '${cleanupWorkerStartupTimeout.inSeconds}s.',
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }
}
