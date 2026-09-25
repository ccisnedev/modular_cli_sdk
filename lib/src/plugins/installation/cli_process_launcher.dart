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

/// How much earlier than [IoCliProcessLauncher]'s own startup timeout the
/// cleanup worker's own deadline for creating its ready marker falls. The
/// worker computes an absolute deadline (Unix epoch milliseconds, UTC) from
/// this margin and the same startup timeout the CLI itself is bounded by,
/// carried in the payload as `markerDeadlineUnixMs`, and refuses to create
/// the marker (deleting nothing) once that deadline has passed.
///
/// This is what closes the race a bare timeout leaves open: without an
/// absolute deadline the worker itself agrees to, a worker that starts
/// slowly could still create the marker (recreating the private directory
/// [IoCliProcessLauncher] already deleted after giving up waiting) after
/// the CLI has already reported [CliCleanupWorkerStartFailure]. With the
/// margin, a marker created before the worker's own deadline always has at
/// least this much time left before the CLI's deadline, and
/// [cleanupWorkerReadyPollInterval] is well under it, so the CLI is
/// guaranteed to observe such a marker before giving up.
const Duration cleanupWorkerMarkerDeadlineSafetyMargin = Duration(seconds: 2);

/// How often [IoCliProcessLauncher.startCleanupWorker] polls for the
/// worker's ready-marker file. Well under
/// [cleanupWorkerMarkerDeadlineSafetyMargin], so a marker the worker
/// created before its own deadline is always observed before the CLI's own,
/// later, [cleanupWorkerStartupTimeout] deadline runs out.
const Duration cleanupWorkerReadyPollInterval = Duration(milliseconds: 50);

/// The environment variable the cleanup worker reads its JSON payload from,
/// directly, as its value: not a path to a file. An environment variable
/// value is inherited by the child through Windows' own, Unicode-safe
/// environment block, so a payload containing non-ASCII paths survives
/// intact; a UTF-8-without-BOM file would not, since Windows PowerShell
/// 5.1's `Get-Content` decodes a BOM-less file using the system ANSI code
/// page, corrupting anything outside it.
const String cleanupWorkerPayloadEnvVar = 'CLI_CLEANUP_PAYLOAD';

/// The environment variable the cleanup worker reads its ready-marker file's
/// path from. That path lives inside a private, randomly named, exclusively
/// created temporary directory (see [IoCliProcessLauncher]), never directly
/// under the shared system temp directory: a predictable name there would
/// let another process on the same machine pre-create or race the same
/// path.
const String cleanupWorkerReadyMarkerPathEnvVar = 'CLI_CLEANUP_READY_PATH';

/// The cleanup worker's bootstrap script, fixed and never interpolated:
/// every piece of run-specific data (which process to wait for, which paths
/// to delete, how long to wait) travels through the environment variable
/// named by [cleanupWorkerPayloadEnvVar], parsed once with
/// `ConvertFrom-Json`. Interpolating a path into a script string is exactly
/// the failure mode this replaces (a path containing `%`, `&`, `!`, quotes
/// or parentheses breaking, or escaping into, the parsing of whatever
/// launched the script); reading it as a JSON string value has none of that
/// risk. [IoCliProcessLauncher] never writes this script to a file either:
/// it is passed to PowerShell whole, Base64-encoded as UTF-16LE, through
/// `-EncodedCommand` (see [cleanupWorkerEncodedBootstrapScript]), so there is
/// no script path for `cmd.exe`'s own command-line grammar to re-parse.
///
/// Sequence: parse the payload, retain a handle on the parent process (if it
/// is still running; a parent that has already exited by the time the
/// worker starts is treated as already gone rather than an error, but any
/// other failure retaining the handle, such as access denied on a
/// protected process, is not, and stops the worker before the ready marker
/// is created), refuse to go on if the payload's own marker-creation
/// deadline has already passed, create the ready-marker file (failing,
/// rather than recreating anything, if the private directory is gone or
/// the marker already exists), wait up to the given timeout for the parent
/// to exit, and only on a confirmed exit delete each given path with
/// `Remove-Item -LiteralPath` under `$ErrorActionPreference = 'Stop'`. A
/// timed-out wait deletes nothing. The worker owns no temporary file of its
/// own to clean up on the way out: the ready-marker file lives inside the
/// private directory [IoCliProcessLauncher] created and is [
/// IoCliProcessLauncher]'s own responsibility to remove, once it has seen
/// the marker (or given up waiting for it).
const String cleanupWorkerBootstrapScript = r'''
$ErrorActionPreference = 'Stop'
$data = $env:CLI_CLEANUP_PAYLOAD | ConvertFrom-Json
$parentPid = [int]$data.parentPid
$paths = @($data.paths)
$timeoutMs = [int]$data.timeoutMs
$markerDeadlineUnixMs = [int64]$data.markerDeadlineUnixMs
$ReadyMarkerPath = $env:CLI_CLEANUP_READY_PATH

$parent = $null
try {
    $parent = [System.Diagnostics.Process]::GetProcessById($parentPid)
} catch [System.ArgumentException] {
    # No process with that id exists: the parent already exited before the
    # worker got a chance to look. Not an error to stop the worker for.
    $parent = $null
}

# Deliberately outside the catch above: any other failure retaining a
# handle on a process that does exist (for example, access denied on a
# protected process) must stop the worker before the ready marker is
# created, so the CLI sees no marker in time and reports
# cleanup-start-failed instead of a worker that silently is not actually
# holding what it needs.
if ($null -ne $parent) {
    $null = $parent.Handle
}

# Closes the race where startCleanupWorker has already given up waiting for
# a marker and deleted the private directory it created. Past this
# deadline the worker refuses to create the marker (or, since File.Open
# with CreateNew never creates a missing parent directory, the directory
# either) and exits, deleting nothing. The CLI polls often enough, well
# under the safety margin baked into this deadline, that a marker created
# before it is always seen before the CLI's own, later deadline runs out.
$nowUnixMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
if ($nowUnixMs -gt $markerDeadlineUnixMs) {
    exit 1
}

# CreateNew fails, rather than silently recreating anything, when the
# private directory is already gone (the CLI gave up waiting and deleted
# it) or when the marker somehow already exists: it never creates a
# missing parent directory the way a forced item creation would.
$markerStream = [System.IO.File]::Open(
    $ReadyMarkerPath,
    [System.IO.FileMode]::CreateNew
)
$markerStream.Close()

$exited = $true
if ($null -ne $parent) {
    $exited = $parent.WaitForExit($timeoutMs)
}

if ($exited) {
    foreach ($path in $paths) {
        Remove-Item -LiteralPath $path
    }
}
''';

/// The UTF-16LE byte encoding of [s]'s UTF-16 code units. [s] is always
/// [cleanupWorkerBootstrapScript] here, which is fixed ASCII text with no
/// character outside the Basic Multilingual Plane, so encoding each
/// `String.codeUnits` entry as two little-endian bytes is exactly UTF-16LE
/// for it; this is not a general-purpose UTF-16LE encoder.
List<int> _utf16LeBytes(String s) {
  final bytes = <int>[];
  for (final unit in s.codeUnits) {
    bytes.add(unit & 0xFF);
    bytes.add((unit >> 8) & 0xFF);
  }
  return bytes;
}

/// [cleanupWorkerBootstrapScript], Base64-encoded as UTF-16LE: exactly the
/// form PowerShell's `-EncodedCommand` requires. Computed once, since the
/// script is fixed and never interpolated with anything run-specific:
/// nothing about a given run's payload, target paths or timeout is baked
/// into this string.
final String cleanupWorkerEncodedBootstrapScript = base64.encode(
  _utf16LeBytes(cleanupWorkerBootstrapScript),
);

/// Characters cmd.exe's own command-line grammar treats specially, on top
/// of ordinary Win32 argv quoting: `&`, `|`, `<` and `>` chain or redirect
/// commands, `^` escapes the next character, `%` expands a variable, `!`
/// expands one under delayed expansion, and `"` can terminate quoting
/// early. [powershellExecutablePath]'s result is the only run-specific
/// value that ever appears on the cmd.exe command line
/// [IoCliProcessLauncher] builds; every other token on it is fixed, and the
/// paths a caller actually wants deleted travel through
/// [cleanupWorkerPayloadEnvVar] instead, never through this command line at
/// all.
final RegExp _cmdMetacharacters = RegExp(r'[&|<>^%!"]');

void _rejectCmdMetacharacters(String path) {
  if (_cmdMetacharacters.hasMatch(path)) {
    throw CliCleanupWorkerStartFailure(
      'Could not start the cleanup worker: the resolved path $path '
      'contains a character cmd.exe treats specially, so it cannot be '
      'passed safely on its command line.',
    );
  }
}

/// Resolves the real Windows PowerShell executable's fixed path from
/// [environment]'s `SystemRoot` entry, the way [IoCliProcessLauncher] does
/// before launching the cleanup worker. Throws
/// [CliCleanupWorkerStartFailure] when `SystemRoot` is absent or empty,
/// rather than falling back to a bare `powershell.exe` that would run
/// whichever executable happens to be first on `PATH`, or an unqualified
/// `powershell` that a hijacked `PATH` could point anywhere; also throws it
/// when the resolved path contains a character cmd.exe's own command-line
/// grammar treats specially, since this path is the only run-specific value
/// that reaches that command line (see [_rejectCmdMetacharacters]).
String powershellExecutablePath(Map<String, String> environment) {
  final systemRoot = environment['SystemRoot'];
  if (systemRoot == null || systemRoot.isEmpty) {
    throw const CliCleanupWorkerStartFailure(
      'Could not start the cleanup worker: the SystemRoot environment '
      'variable is not set.',
    );
  }
  final path = '$systemRoot\\System32\\WindowsPowerShell\\v1.0\\powershell.exe';
  _rejectCmdMetacharacters(path);
  return path;
}

/// Resolves the real `cmd.exe`'s fixed path from [environment]'s
/// `SystemRoot` entry, for the same `SystemRoot`-absent reason
/// [powershellExecutablePath] resolves PowerShell's: never a bare
/// `cmd.exe`/`cmd` that trusts `PATH`. Unlike [powershellExecutablePath]'s
/// result, this path is never itself an argument on any command line
/// `cmd.exe` re-parses (it is the process [IoCliProcessLauncher] launches
/// directly, resolved by Windows' own `CreateProcess`, not tokenised by
/// `cmd.exe`'s shell grammar), so it needs no metacharacter check.
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

/// The fixed argument list [IoCliProcessLauncher.startCleanupWorker] passes
/// to [cmdExecutablePath]'s process, given the resolved [powershellPath].
/// Every entry is a fixed literal token except [powershellPath] itself,
/// already validated by [powershellExecutablePath] to contain no character
/// cmd.exe treats specially, and [cleanupWorkerEncodedBootstrapScript],
/// which is fixed and carries no run-specific data. No path the caller
/// wants deleted, and no payload of any kind, appears here.
List<String> _cleanupWorkerCmdArgs(String powershellPath) => [
  '/d',
  '/c',
  'start',
  '""',
  '/min',
  powershellPath,
  '-NoProfile',
  '-NonInteractive',
  '-EncodedCommand',
  cleanupWorkerEncodedBootstrapScript,
];

/// The full command line [IoCliProcessLauncher.startCleanupWorker] passes to
/// [cmdPath], built the same way it builds it for a real launch, given
/// [powershellPath]. Exists as a pure function so a test can assert its
/// length stays well under cmd.exe's roughly 8191-character command-line
/// limit without launching a real process:
/// [cleanupWorkerEncodedBootstrapScript] is by far its largest component,
/// and it is fixed, so this is deterministic.
String cleanupWorkerCmdCommandLine(String cmdPath, String powershellPath) =>
    '$cmdPath ${_cleanupWorkerCmdArgs(powershellPath).join(' ')}';

/// The process identity and cleanup-worker-launching capability
/// [SelfDeleteExecutableStep] needs to remove a running Windows executable.
/// Injectable for the same reason [CliFileSystem] is: a test supplies a fake
/// that records what was launched, in place of actually launching a real
/// PowerShell worker and waiting on a real PID.
abstract class CliProcessLauncher {
  /// This process's own process id.
  int get currentPid;

  /// Starts the detached PowerShell cleanup worker, passes it [payload] as
  /// JSON through an environment variable, and waits for it to confirm
  /// readiness (its ready-marker file existing) within
  /// [cleanupWorkerStartupTimeout].
  ///
  /// [payload] carries `parentPid` (the process the worker waits on),
  /// `paths` (what it deletes once that process exits) and `timeoutMs` (how
  /// long it waits before giving up). It is written as-is, as JSON: no part
  /// of it is interpolated into a script or a command line, so nothing in
  /// it needs shell escaping.
  ///
  /// Returns null on a clean success, or a warning naming a problem that
  /// does not change the outcome (currently: the implementation's own
  /// private temporary directory could not be removed once the worker
  /// confirmed ready) but that a caller must not discard either.
  ///
  /// Throws [CliCleanupWorkerStartFailure] when the worker cannot be started
  /// at all, or does not confirm readiness in time. A worker that starts,
  /// confirms readiness, and then fails on its own later (after this process
  /// has already exited, with nobody left to observe it) is not this
  /// method's concern.
  Future<String?> startCleanupWorker(Map<String, Object?> payload);
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
/// `cmd.exe` re-parses its own command line with its own shell grammar, on
/// top of ordinary argv quoting: a value on that line containing `&`, `%`,
/// `^` or similar can break out of, or inject into, the command it was
/// meant to be an argument of. So nothing environment-controlled or
/// caller-supplied ever appears there: the command line built here carries
/// only fixed literal tokens plus [powershellExecutablePath]'s result
/// (itself checked to contain none of those characters). There is no script
/// file and no `-File <path>` argument either; the fixed bootstrap script is
/// passed whole through `-EncodedCommand`, Base64-encoded as UTF-16LE (see
/// [cleanupWorkerEncodedBootstrapScript]). The payload (the paths to delete,
/// the parent pid, the timeout) travels as JSON through the environment
/// variable named by [cleanupWorkerPayloadEnvVar], inherited by the child
/// through Windows' own Unicode-safe environment block rather than a
/// UTF-8-without-BOM file Windows PowerShell 5.1's `Get-Content` would
/// misdecode.
///
/// The ready marker the worker creates to confirm it is alive and holding
/// what it needs lives inside a private temporary directory, created here
/// with [io.Directory.createTemp] (atomic, exclusive, randomly named), never
/// directly under the shared system temp directory with a predictable
/// pid/timestamp name another process on the same machine could pre-create
/// or race. That directory's path is never passed on any command line
/// either; only the ready-marker file's own path, inside it, travels
/// through the environment variable named by
/// [cleanupWorkerReadyMarkerPathEnvVar]. This class removes that directory
/// itself once it has seen the marker, or once it gives up waiting for one,
/// so nothing is left behind either way.
class IoCliProcessLauncher implements CliProcessLauncher {
  /// [startupTimeout] and [markerDeadlineSafetyMargin] override
  /// [cleanupWorkerStartupTimeout] and
  /// [cleanupWorkerMarkerDeadlineSafetyMargin] respectively. A test uses
  /// this to make the deadline the worker itself refuses to create the
  /// marker past fall a handful of milliseconds after launch, deterministic
  /// ally provoking the case a real, slow worker start could otherwise only
  /// hit by chance.
  const IoCliProcessLauncher({
    Duration startupTimeout = cleanupWorkerStartupTimeout,
    Duration markerDeadlineSafetyMargin =
        cleanupWorkerMarkerDeadlineSafetyMargin,
  }) : _startupTimeout = startupTimeout,
       _markerDeadlineSafetyMargin = markerDeadlineSafetyMargin;

  final Duration _startupTimeout;
  final Duration _markerDeadlineSafetyMargin;

  @override
  int get currentPid => io.pid;

  @override
  Future<String?> startCleanupWorker(Map<String, Object?> payload) async {
    final environment = io.Platform.environment;
    final powershellPath = powershellExecutablePath(environment);
    final cmdPath = cmdExecutablePath(environment);

    final io.Directory privateDir;
    try {
      privateDir = io.Directory.systemTemp.createTempSync('cli_cleanup_');
    } on Object catch (e) {
      throw CliCleanupWorkerStartFailure(
        'Could not start the cleanup worker: could not create a private '
        'temporary directory for it: $e',
      );
    }

    CliCleanupWorkerStartFailure? startFailure;
    try {
      final readyMarkerPath =
          '${privateDir.path}${io.Platform.pathSeparator}ready';

      final startedAt = DateTime.now();
      // A single origin for both deadlines below: the worker's own,
      // carried through the payload as Unix epoch milliseconds (UTC, so
      // both processes compare it against the same origin regardless of
      // local time zone), and the CLI's own further down, kept a fixed
      // safety margin apart so the CLI's poll interval always has time to
      // observe a marker the worker created in time.
      final markerDeadlineUnixMs =
          startedAt.toUtc().millisecondsSinceEpoch +
          (_startupTimeout - _markerDeadlineSafetyMargin).inMilliseconds;
      final effectivePayload = Map<String, Object?>.from(payload)
        ..['markerDeadlineUnixMs'] = markerDeadlineUnixMs;

      final workerEnvironment = Map<String, String>.from(environment)
        ..[cleanupWorkerPayloadEnvVar] = jsonEncode(effectivePayload)
        ..[cleanupWorkerReadyMarkerPathEnvVar] = readyMarkerPath;

      // Deliberately Process.start, awaiting only exitCode, never
      // stdout/stderr: cmd.exe's `start` hands the worker off to a process
      // outside cmd.exe's own tree, but that worker can still inherit
      // cmd.exe's stdout/stderr pipe handles. Process.run would wait for
      // those pipes to see end-of-file, which does not happen until the
      // long-lived worker itself exits, minutes later. Only the launcher's
      // own exit code is this call's concern.
      final io.Process launcher;
      try {
        launcher = await io.Process.start(
          cmdPath,
          _cleanupWorkerCmdArgs(powershellPath),
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

      final cliDeadline = startedAt.add(_startupTimeout);
      while (!io.File(readyMarkerPath).existsSync()) {
        if (DateTime.now().isAfter(cliDeadline)) {
          throw CliCleanupWorkerStartFailure(
            'The cleanup worker did not confirm it was ready within '
            '${_startupTimeout.inSeconds}s.',
          );
        }
        await Future<void>.delayed(cleanupWorkerReadyPollInterval);
      }
    } on CliCleanupWorkerStartFailure catch (e) {
      startFailure = e;
    }

    // Whether the worker confirmed ready or startCleanupWorker gave up
    // waiting for it, nothing after this point needs the private
    // directory, and leaving it behind on every run of a long-lived CLI is
    // exactly the leak this removes. Unlike a bare "best effort" catch,
    // though, a failure to remove it here is not discarded: it is folded
    // into the CliCleanupWorkerStartFailure above when there is one, or
    // returned as a warning on the success path, because a leftover
    // private directory is exactly the kind of thing a caller (and,
    // through it, an operator reading uninstall's own output) needs to be
    // told about rather than have hidden from them.
    String? cleanupFailureDetail;
    try {
      deletePrivateDirectory(privateDir);
    } on Object catch (e) {
      cleanupFailureDetail =
          'could not remove its private temporary directory '
          '${privateDir.path}: $e';
    }

    if (startFailure != null) {
      if (cleanupFailureDetail == null) throw startFailure;
      throw CliCleanupWorkerStartFailure(
        '${startFailure.message} Additionally, $cleanupFailureDetail.',
      );
    }

    if (cleanupFailureDetail == null) return null;
    return 'The cleanup worker started successfully, but '
        '$cleanupFailureDetail.';
  }

  /// Removes [privateDir], if it still exists, once
  /// [startCleanupWorker] no longer needs it. Exposed as its own
  /// overridable method purely as a test seam: a subclass in a test can
  /// override this to throw on demand, which is the only way to exercise
  /// startCleanupWorker's own handling of a cleanup failure, since nothing
  /// portable lets a test provoke a real directory-deletion failure at
  /// exactly this point otherwise. Production code never overrides this.
  void deletePrivateDirectory(io.Directory privateDir) {
    if (privateDir.existsSync()) {
      privateDir.deleteSync(recursive: true);
    }
  }
}
