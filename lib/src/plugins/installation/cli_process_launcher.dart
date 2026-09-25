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

/// The ready-marker file's own name, inside the private directory
/// [IoCliProcessLauncher] creates. The CLI builds the marker's full path
/// from this name and the private directory's own path; the worker
/// receives that same full path directly, through
/// [cleanupWorkerReadyMarkerPathEnvVar].
const String cleanupWorkerReadyMarkerFileName = 'ready';

/// The name of the marker file [tryClaimReadyMarker] renames the ready
/// marker to when the CLI wins the single-winner claim. A sibling of the
/// ready marker, inside the same private directory.
const String cleanupWorkerAcceptedMarkerFileName = 'accepted';

/// The name of the marker file the cleanup worker's own bootstrap script
/// renames the ready marker to when it wins the single-winner claim by
/// reaching its own claim deadline first. A sibling of the ready marker,
/// inside the same private directory.
const String cleanupWorkerAbandonedMarkerFileName = 'abandoned';

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
/// is created; the handle is retrieved through the explicit `get_Handle()`
/// accessor, not the bare `.Handle` property, since Windows PowerShell
/// 5.1's property-getter syntax has been observed to return `$null`
/// instead of throwing on an access-denied process even under
/// `$ErrorActionPreference = 'Stop'`, and the returned handle is itself
/// validated as non-null and non-zero before going on), refuse to go on if
/// the payload's own marker-creation deadline has already passed, create
/// the ready-marker file (failing, rather than recreating anything, if the
/// private directory is gone or the marker already exists).
///
/// From there, an absolute deadline alone cannot decide who wins the race
/// against [IoCliProcessLauncher]: a CLI thread suspended right up to its
/// own deadline can still resume after it and disagree with a worker that
/// created its marker in time. So the worker and the CLI instead settle it
/// with a single atomic rename, the only primitive where exactly one of
/// two competing attempts can ever succeed: the CLI claims by renaming the
/// ready marker to [cleanupWorkerAcceptedMarkerFileName]
/// ([IoCliProcessLauncher.startCleanupWorker]'s own [tryClaimReadyMarker]
/// seam does this); the worker below claims abandonment, past its own
/// `claimDeadlineUnixMs`, by renaming the same ready marker to
/// [cleanupWorkerAbandonedMarkerFileName] with `[System.IO.File]::Move`,
/// which throws cleanly when the source is already gone. Deletion is armed
/// only once the accepted marker is actually observed to exist, whether
/// while still polling for it or, after a failed abandon rename, as
/// confirmation that the rename failed because the CLI's claim really did
/// win first, not for some other reason. Only when armed does the worker
/// wait up to the given timeout for the parent to exit and, on a confirmed
/// exit, delete each given path with `Remove-Item -LiteralPath` under
/// `$ErrorActionPreference = 'Stop'`, followed by its own private
/// directory: ownership of removing it belongs to the worker on this path,
/// never to [IoCliProcessLauncher], since deleting it immediately after a
/// successful claim would race the worker's own, still-pending, first look
/// at the accepted marker. A worker that never arms deletes nothing and
/// leaves the private directory for [IoCliProcessLauncher] to remove, the
/// same as a worker that never even reaches the ready marker.
const String cleanupWorkerBootstrapScript = r'''
$ErrorActionPreference = 'Stop'
$data = $env:CLI_CLEANUP_PAYLOAD | ConvertFrom-Json
$parentPid = [int]$data.parentPid
$paths = @($data.paths)
$timeoutMs = [int]$data.timeoutMs
$markerDeadlineUnixMs = [int64]$data.markerDeadlineUnixMs
$claimDeadlineUnixMs = [int64]$data.claimDeadlineUnixMs
$ReadyMarkerPath = $env:CLI_CLEANUP_READY_PATH
$PrivateDir = Split-Path -Parent $ReadyMarkerPath
$AcceptedMarkerPath = Join-Path $PrivateDir 'accepted'
$AbandonedMarkerPath = Join-Path $PrivateDir 'abandoned'

$parent = $null
try {
    $parent = [System.Diagnostics.Process]::GetProcessById($parentPid)
} catch [System.ArgumentException] {
    $parent = $null
}

if ($null -ne $parent) {
    $handle = $parent.get_Handle()
    if ($null -eq $handle -or $handle -eq [IntPtr]::Zero) {
        exit 1
    }
}

$nowUnixMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
if ($nowUnixMs -gt $markerDeadlineUnixMs) {
    exit 1
}

$markerStream = [System.IO.File]::Open(
    $ReadyMarkerPath,
    [System.IO.FileMode]::CreateNew
)
$markerStream.Close()

$armed = $false
while ($true) {
    if (Test-Path -LiteralPath $AcceptedMarkerPath) {
        $armed = $true
        break
    }
    $nowUnixMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    if ($nowUnixMs -gt $claimDeadlineUnixMs) {
        try {
            [System.IO.File]::Move($ReadyMarkerPath, $AbandonedMarkerPath)
        } catch {
        }
        if (Test-Path -LiteralPath $AcceptedMarkerPath) {
            $armed = $true
        }
        break
    }
    Start-Sleep -Milliseconds 50
}

if ($armed) {
    $exited = $true
    if ($null -ne $parent) {
        $exited = $parent.WaitForExit($timeoutMs)
    }
    if ($exited) {
        foreach ($path in $paths) {
            Remove-Item -LiteralPath $path
        }
        Remove-Item -LiteralPath $PrivateDir -Recurse
    }
}
''';

/// Attempts the single-winner claim of the ready marker at
/// [readyMarkerPath], atomically renaming it to [acceptedMarkerPath].
/// Returns true when the rename succeeded: this call, and only this call
/// (or the worker's own competing rename to the abandoned marker, exactly
/// one of the two), won the claim, since a rename of a source path that no
/// longer exists always fails. Returns false, creating nothing, when the
/// ready marker does not exist to rename, whether because the worker
/// never created it yet or because the worker's own rename already won.
///
/// This is the exact primitive [IoCliProcessLauncher.startCleanupWorker]
/// and [cleanupWorkerBootstrapScript] each use, on either side of the same
/// race, to decide the claim with a single atomic filesystem operation
/// rather than by comparing two independently read clocks: pulled out as
/// its own pure, synchronous function so a test can exercise both a win
/// and a loss directly, against real files, without needing a real
/// subprocess or a suspended thread to provoke either deterministically.
bool tryClaimReadyMarker(String readyMarkerPath, String acceptedMarkerPath) {
  try {
    io.File(readyMarkerPath).renameSync(acceptedMarkerPath);
    return true;
  } on io.FileSystemException {
    return false;
  }
}

/// Polls [tryClaimReadyMarker] against [readyMarkerPath] and
/// [acceptedMarkerPath] until it wins the claim or [deadline] (read
/// through [now]) passes, waiting [pollInterval] between attempts.
///
/// The claim is always attempted first, before [deadline] is even
/// checked, on every iteration including the first: this is what closes
/// the exact race Codex described, where a CLI thread is suspended right
/// up to its own deadline and only resumes after it. A deadline check
/// alone would give up right away without ever trying again; attempting
/// the claim first means a marker the worker created in time is still won
/// even by a caller whose own clock already reads past the deadline by
/// the time it gets to run at all.
///
/// [now] and [pollInterval] are both injectable so a test can exercise
/// both outcomes, winning and losing, deterministically rather than
/// depending on real wall-clock timing.
Future<bool> pollForClaim({
  required String readyMarkerPath,
  required String acceptedMarkerPath,
  required DateTime deadline,
  required Duration pollInterval,
  required DateTime Function() now,
}) async {
  while (true) {
    if (tryClaimReadyMarker(readyMarkerPath, acceptedMarkerPath)) {
      return true;
    }
    if (!now().isBefore(deadline)) {
      return false;
    }
    await Future<void>.delayed(pollInterval);
  }
}

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
  /// Completes on a clean success: the worker has won the single-winner
  /// claim over the ready marker and now owns deleting the given paths,
  /// and its own private directory, once the watched process exits.
  ///
  /// Throws [CliCleanupWorkerStartFailure] when the worker cannot be started
  /// at all, does not confirm readiness in time, or never wins the claim
  /// (having abandoned it, or the claim deadline having passed). A worker
  /// that wins the claim and then fails on its own later (after this
  /// process has already exited, with nobody left to observe it) is not
  /// this method's concern.
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
/// [cleanupWorkerReadyMarkerPathEnvVar].
///
/// Who removes that directory depends on which side wins the single-winner
/// claim over the ready marker (see [tryClaimReadyMarker],
/// [pollForClaim] and [cleanupWorkerBootstrapScript]): when this class's own
/// claim never succeeds, whether because the worker never confirmed ready
/// or because the worker abandoned the claim first, this class removes the
/// directory itself before returning, the same as before there was a claim
/// to make at all. When this class's claim succeeds, the worker owns
/// removing the directory instead, once it has actually finished deleting
/// the given paths: removing it here immediately after a successful claim
/// would race the worker's own, still-pending, first look at the accepted
/// marker, and a directory gone before the worker ever observes that marker
/// is indistinguishable, to the worker, from never having been claimed at
/// all.
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
  Future<void> startCleanupWorker(Map<String, Object?> payload) async {
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
          '${privateDir.path}${io.Platform.pathSeparator}'
          '$cleanupWorkerReadyMarkerFileName';
      final acceptedMarkerPath =
          '${privateDir.path}${io.Platform.pathSeparator}'
          '$cleanupWorkerAcceptedMarkerFileName';

      final startedAt = DateTime.now();
      // A single origin for all three deadlines below: the worker's own
      // marker-creation deadline and claim deadline, both carried through
      // the payload as Unix epoch milliseconds (UTC, so both processes
      // compare them against the same origin regardless of local time
      // zone), and this class's own poll deadline further down. The
      // marker-creation deadline is kept a fixed safety margin ahead of
      // this class's poll deadline so its poll interval always has time to
      // observe a marker the worker created in time; the claim deadline
      // matches this class's own poll deadline exactly, since the claim
      // itself, not either side's clock, is what decides who wins once a
      // marker exists.
      final markerDeadlineUnixMs =
          startedAt.toUtc().millisecondsSinceEpoch +
          (_startupTimeout - _markerDeadlineSafetyMargin).inMilliseconds;
      final cliDeadline = startedAt.add(_startupTimeout);
      final claimDeadlineUnixMs = cliDeadline.toUtc().millisecondsSinceEpoch;
      final effectivePayload = Map<String, Object?>.from(payload)
        ..['markerDeadlineUnixMs'] = markerDeadlineUnixMs
        ..['claimDeadlineUnixMs'] = claimDeadlineUnixMs;

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

      final claimed = await pollForClaim(
        readyMarkerPath: readyMarkerPath,
        acceptedMarkerPath: acceptedMarkerPath,
        deadline: cliDeadline,
        pollInterval: cleanupWorkerReadyPollInterval,
        now: DateTime.now,
      );
      if (!claimed) {
        throw CliCleanupWorkerStartFailure(
          'The cleanup worker did not confirm it was ready within '
          '${_startupTimeout.inSeconds}s.',
        );
      }

      // The claim succeeded: the worker now owns deleting the given paths,
      // and its own private directory, once the watched process exits.
      // Nothing further here needs, or may touch, that directory; see the
      // class doc comment for why removing it here would race the
      // worker's own, still-pending, first look at the marker this call
      // just created.
      return;
    } on CliCleanupWorkerStartFailure catch (e) {
      startFailure = e;
    }

    // Reached only when the claim was never made: the worker never
    // confirmed ready in time, or it abandoned the claim first. Either
    // way, nothing after this point needs the private directory, and
    // leaving it behind on every run of a long-lived CLI is exactly the
    // leak this removes. Unlike a bare "best effort" catch, though, a
    // failure to remove it here is not discarded: it is folded into the
    // CliCleanupWorkerStartFailure below, because a leftover private
    // directory is exactly the kind of thing a caller (and, through it, an
    // operator reading uninstall's own output) needs to be told about
    // rather than have hidden from them.
    final failure = startFailure;
    String? cleanupFailureDetail;
    try {
      deletePrivateDirectory(privateDir);
    } on Object catch (e) {
      cleanupFailureDetail =
          'could not remove its private temporary directory '
          '${privateDir.path}: $e';
    }

    if (cleanupFailureDetail == null) throw failure;
    throw CliCleanupWorkerStartFailure(
      '${failure.message} Additionally, $cleanupFailureDetail.',
    );
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
