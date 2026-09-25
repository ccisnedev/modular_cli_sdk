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

/// How much longer, past [IoCliProcessLauncher]'s own claim deadline
/// (`claimDeadlineUnixMs`, the same instant [cleanupWorkerAbandonedMarkerFileName]
/// is judged against), it goes on waiting to observe the worker's own
/// Phase 2 arm marker ([cleanupWorkerArmedMarkerFileName]) before
/// concluding the worker will never arm and revoking its own claim instead
/// by renaming the accepted marker to [cleanupWorkerRevokedMarkerFileName].
/// Carried to the worker as `ackDeadlineUnixMs`, the same absolute instant
/// computed from this duration added to the claim deadline, so both sides
/// agree on it: past it, the worker's own retries of an unexpected rename
/// failure (see [cleanupWorkerBootstrapScript]) give up and record
/// [cleanupWorkerFailedMarkerFileName] rather than retrying forever, and
/// [IoCliProcessLauncher] attempts its own competing rename rather than
/// waiting forever for a worker that may already be dead. This closes the
/// race where a worker crashes, or is killed, between creating its ready
/// marker and ever reaching the accepted marker it would otherwise have
/// armed: nothing ever arms it, so this deadline, not a bare successful
/// Phase 1 claim, is what decides whether [IoCliProcessLauncher] may report
/// success.
const Duration cleanupWorkerAckTimeout = Duration(seconds: 5);

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

/// The name of the marker file the cleanup worker's own bootstrap script
/// renames the accepted marker to when it wins the single-winner Phase 2
/// claim: the worker, not [IoCliProcessLauncher], owns this rename, since
/// arming deletion is the worker's own decision to make. A sibling of the
/// ready marker, inside the same private directory.
const String cleanupWorkerArmedMarkerFileName = 'armed';

/// The name of the marker file [tryRevokeAcceptedMarker] renames the
/// accepted marker to when [IoCliProcessLauncher] wins the single-winner
/// Phase 2 claim by reaching [cleanupWorkerAckTimeout]'s deadline before
/// observing [cleanupWorkerArmedMarkerFileName]. A sibling of the ready
/// marker, inside the same private directory.
const String cleanupWorkerRevokedMarkerFileName = 'revoked';

/// The name of the marker file the cleanup worker's own bootstrap script
/// creates, best effort, when an unexpected failure (anything other than
/// the source of a rename simply no longer existing) keeps it from ever
/// completing either its abandon rename or its arm rename before
/// [cleanupWorkerAckTimeout]'s deadline. Named so an operator inspecting a
/// leftover private directory by hand can tell this case apart from an
/// ordinary abandoned or revoked claim. Never read back by
/// [IoCliProcessLauncher] itself: by the time it could exist, this class has
/// already given up and reported [CliCleanupWorkerStartFailure].
const String cleanupWorkerFailedMarkerFileName = 'failed';

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
/// two competing attempts can ever succeed, in two phases.
///
/// Phase 1 (unchanged in shape): the CLI claims by renaming the ready
/// marker to [cleanupWorkerAcceptedMarkerFileName]
/// ([IoCliProcessLauncher.startCleanupWorker]'s own [tryClaimReadyMarker]
/// seam does this); the worker below claims abandonment, past its own
/// `claimDeadlineUnixMs`, by renaming the same ready marker to
/// [cleanupWorkerAbandonedMarkerFileName] with `[System.IO.File]::Move`,
/// which throws cleanly when the source is already gone.
///
/// Phase 2 (new): a successful Phase 1 CLI claim alone is not enough to
/// arm anything, since the worker that would eventually arm it might
/// already be dead (crashed, or killed, between creating its ready marker
/// and ever observing the accepted marker), leaving nothing to ever arm a
/// claim the CLI already thinks it won. So the worker, once it observes
/// (or, after losing its own abandon rename with a legitimate "source not
/// found" failure, infers) that the accepted marker exists, races to arm
/// deletion itself by renaming it to [cleanupWorkerArmedMarkerFileName],
/// again with `[System.IO.File]::Move`. [IoCliProcessLauncher] only
/// reports success once it has actually observed that rename's result,
/// never merely from winning Phase 1: past its own `ackDeadlineUnixMs`
/// deadline without observing it, it instead renames the accepted marker
/// to [cleanupWorkerRevokedMarkerFileName] itself; if that rename wins,
/// the worker (whether dead or merely slow) never armed in time and
/// [IoCliProcessLauncher] reports failure; if it loses because the worker's
/// own rename already won, [IoCliProcessLauncher] reports success even
/// though its own revoke attempt failed. A worker that loses its own arm
/// rename because the accepted marker is already gone (the CLI's revoke
/// won first) exits without deleting anything.
///
/// Neither rename attempt below, the abandon one or the arm one, ever
/// swallows a failure that is not simply the source no longer existing: a
/// failure of that kind (a sharing violation being the concrete case
/// observed in practice) is retried on the same poll interval used
/// elsewhere in this script, for as long as `ackDeadlineUnixMs` allows,
/// rather than treated as an ordinary lost race; a worker that gave up
/// silently here would leave a still-claimable marker behind for a later,
/// wrong claimant. Only once that deadline passes without the retried
/// rename ever succeeding does the worker record
/// [cleanupWorkerFailedMarkerFileName], best effort, and exit.
///
/// Only once armed does the worker wait for the parent to exit, with no
/// time limit at all (`$parent.WaitForExit()`, not the bounded overload):
/// an armed deletion stays armed until the parent genuinely exits, however
/// long that takes, rather than risk deleting out from under a parent that
/// is merely slow to shut down. On a confirmed exit (or immediately, when
/// the parent had already exited before the worker ever retained a
/// handle), it deletes each given path with `Remove-Item -LiteralPath`
/// under `$ErrorActionPreference = 'Stop'`, followed by its own private
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
$markerDeadlineUnixMs = [int64]$data.markerDeadlineUnixMs
$claimDeadlineUnixMs = [int64]$data.claimDeadlineUnixMs
$ackDeadlineUnixMs = [int64]$data.ackDeadlineUnixMs
$ReadyMarkerPath = $env:CLI_CLEANUP_READY_PATH
$PrivateDir = Split-Path -Parent $ReadyMarkerPath
$AcceptedMarkerPath = Join-Path $PrivateDir 'accepted'
$AbandonedMarkerPath = Join-Path $PrivateDir 'abandoned'
$ArmedMarkerPath = Join-Path $PrivateDir 'armed'
$FailedMarkerPath = Join-Path $PrivateDir 'failed'

function Complete-Rename($From, $To) {
    while ($true) {
        try {
            [System.IO.File]::Move($From, $To)
            return $true
        } catch [System.IO.FileNotFoundException] {
            return $false
        } catch {
            $nowUnixMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
            if ($nowUnixMs -gt $ackDeadlineUnixMs) {
                try {
                    $s = [System.IO.File]::Open($FailedMarkerPath, [System.IO.FileMode]::Create)
                    $s.Close()
                } catch {
                    exit 1
                }
                exit 1
            }
            Start-Sleep -Milliseconds 50
        }
    }
}

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

while ($true) {
    if (Test-Path -LiteralPath $AcceptedMarkerPath) {
        break
    }
    $nowUnixMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    if ($nowUnixMs -gt $claimDeadlineUnixMs) {
        if (Complete-Rename $ReadyMarkerPath $AbandonedMarkerPath) {
            exit 0
        }
        break
    }
    Start-Sleep -Milliseconds 50
}

$armed = Complete-Rename $AcceptedMarkerPath $ArmedMarkerPath

if ($armed) {
    if ($null -ne $parent) {
        $parent.WaitForExit()
    }
    foreach ($path in $paths) {
        Remove-Item -LiteralPath $path
    }
    Remove-Item -LiteralPath $PrivateDir -Recurse
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
///
/// A failure that is not simply the source no longer existing (a sharing
/// violation being the concrete case Codex reported, where another handle
/// on the ready marker keeps the rename itself from completing at all) is
/// not folded into that same "lost the claim" false either: it is
/// rethrown, since treating a rename that never actually happened as an
/// ordinary loss would let [IoCliProcessLauncher] wrongly stop polling and
/// report [CliCleanupWorkerStartFailure] for a marker that, for all this
/// call knows, the worker never got a real chance to compete for.
bool tryClaimReadyMarker(String readyMarkerPath, String acceptedMarkerPath) {
  try {
    io.File(readyMarkerPath).renameSync(acceptedMarkerPath);
    return true;
  } on io.FileSystemException catch (e) {
    if (_isSourceNotFoundError(e)) return false;
    rethrow;
  }
}

/// Attempts [IoCliProcessLauncher]'s own single-winner Phase 2 claim: an
/// atomic rename of [acceptedMarkerPath] to [revokedMarkerPath]. Returns
/// true when the rename succeeded: the worker never won its own competing
/// rename to [cleanupWorkerArmedMarkerFileName] in time, so
/// [IoCliProcessLauncher] revoked the claim it made in Phase 1 and must
/// report [CliCleanupWorkerStartFailure] rather than success. Returns
/// false, creating nothing, when the accepted marker no longer exists to
/// rename, because the worker's own rename to the armed marker already won
/// that race first: in that case [IoCliProcessLauncher] reports success
/// even though this call itself lost.
///
/// The same distinction [tryClaimReadyMarker] makes applies here: a
/// failure that is not simply the source no longer existing is rethrown,
/// not folded into an ordinary lost race, so [IoCliProcessLauncher] surfaces
/// it as a typed [CliCleanupWorkerStartFailure] with detail rather than
/// silently reporting either outcome for a rename that never actually ran
/// to completion.
bool tryRevokeAcceptedMarker(String acceptedMarkerPath, String revokedMarkerPath) {
  try {
    io.File(acceptedMarkerPath).renameSync(revokedMarkerPath);
    return true;
  } on io.FileSystemException catch (e) {
    if (_isSourceNotFoundError(e)) return false;
    rethrow;
  }
}

/// Windows' `ERROR_FILE_NOT_FOUND`. A rename failing with this code, or
/// [_errorPathNotFound], because its source no longer exists, is a
/// legitimate loss of a single-winner claim: the other side's own rename
/// already won by removing that same source first. Any other code means
/// the rename itself did not run to completion for some other reason (a
/// sharing violation being the concrete case observed in practice) and
/// must never be folded into "lost the race" by [tryClaimReadyMarker] or
/// [tryRevokeAcceptedMarker].
const int _errorFileNotFound = 2;

/// Windows' `ERROR_PATH_NOT_FOUND`, the other legitimate-loss code; see
/// [_errorFileNotFound].
const int _errorPathNotFound = 3;

bool _isSourceNotFoundError(io.FileSystemException e) {
  final code = e.osError?.errorCode;
  return code == _errorFileNotFound || code == _errorPathNotFound;
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
///
/// Round 7 finding 2's fix, applied symmetrically on this side of the same
/// race: [tryClaimReadyMarker] rethrows an unexpected rename failure (a
/// transient sharing violation, most concretely, of the kind a freshly
/// created file can briefly see on Windows) rather than folding it into an
/// ordinary lost claim. Letting that propagate out of this loop on its
/// first occurrence would abandon polling over exactly the kind of blip
/// the next attempt, [pollInterval] later, would otherwise have ridden
/// out; this catches it and keeps retrying like any other failed
/// attempt, and only lets it propagate once [deadline] has already
/// passed, so the caller still sees the real, specific failure once there
/// is genuinely no time left to retry it.
Future<bool> pollForClaim({
  required String readyMarkerPath,
  required String acceptedMarkerPath,
  required DateTime deadline,
  required Duration pollInterval,
  required DateTime Function() now,
}) async {
  while (true) {
    try {
      if (tryClaimReadyMarker(readyMarkerPath, acceptedMarkerPath)) {
        return true;
      }
    } on io.FileSystemException {
      if (!now().isBefore(deadline)) rethrow;
      await Future<void>.delayed(pollInterval);
      continue;
    }
    if (!now().isBefore(deadline)) {
      return false;
    }
    await Future<void>.delayed(pollInterval);
  }
}

/// Polls for [armedMarkerPath] to exist until it does, or [deadline] (read
/// through [now]) passes, waiting [pollInterval] between checks. Returns
/// true once the marker is observed.
///
/// Unlike [pollForClaim], this never attempts a rename itself: arming is
/// the worker's own decision to make, by winning its own competing rename
/// to [cleanupWorkerArmedMarkerFileName] (see [cleanupWorkerBootstrapScript]);
/// [IoCliProcessLauncher] only ever observes whether that rename has
/// already happened. This is the seam that closes the race where a
/// worker crashes, or is killed, between creating its ready marker and
/// ever reaching the accepted marker it would otherwise have armed: a bare
/// successful Phase 1 claim is not, on its own, proof that anyone is left
/// to arm it, so [IoCliProcessLauncher.startCleanupWorker] never reports
/// success from that alone.
///
/// [now] and [pollInterval] are both injectable so a test can exercise
/// both outcomes deterministically rather than depending on real
/// wall-clock timing.
Future<bool> pollForArm({
  required String armedMarkerPath,
  required DateTime deadline,
  required Duration pollInterval,
  required DateTime Function() now,
}) async {
  while (true) {
    if (io.File(armedMarkerPath).existsSync()) {
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
  /// [payload] carries `parentPid` (the process the worker waits on) and
  /// `paths` (what it deletes once that process exits). It is written
  /// as-is, as JSON: no part of it is interpolated into a script or a
  /// command line, so nothing in it needs shell escaping. There is no
  /// timeout field: once armed, the worker waits for the parent to exit
  /// with no time limit at all.
  ///
  /// Completes on a clean success: the worker has won both the Phase 1
  /// claim over the ready marker and the Phase 2 race to arm deletion, and
  /// now owns deleting the given paths, and its own private directory,
  /// once the watched process exits.
  ///
  /// Throws [CliCleanupWorkerStartFailure] when the worker cannot be started
  /// at all, does not confirm readiness in time, never wins the Phase 1
  /// claim (having abandoned it, or the claim deadline having passed), or
  /// wins Phase 1 but never arms deletion before this call's own ack
  /// deadline, whether because the worker crashed before ever observing
  /// the accepted marker or because it was simply too slow. A worker that
  /// arms and then fails on its own later (after this process has already
  /// exited, with nobody left to observe it) is not this method's concern.
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
/// Who removes that directory depends on which side wins the two-phase
/// single-winner claim (see [tryClaimReadyMarker], [pollForClaim],
/// [pollForArm], [tryRevokeAcceptedMarker] and [cleanupWorkerBootstrapScript]):
/// when this class's own Phase 1 claim never succeeds, when it succeeds but
/// this class's own Phase 2 revoke then wins instead (the worker never
/// armed in time, whether crashed or merely slow), this class removes the
/// directory itself before returning, the same as before there was a claim
/// to make at all. Only when the worker itself wins Phase 2, arming
/// deletion, does the worker instead own removing the directory, once it
/// has actually finished deleting the given paths: removing it here
/// immediately after a successful Phase 1 claim alone would race the
/// worker's own, still-pending, attempt to arm against the accepted marker,
/// and a directory gone before the worker ever gets to make that attempt is
/// indistinguishable, to the worker, from never having been claimed at all.
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
      final armedMarkerPath =
          '${privateDir.path}${io.Platform.pathSeparator}'
          '$cleanupWorkerArmedMarkerFileName';
      final revokedMarkerPath =
          '${privateDir.path}${io.Platform.pathSeparator}'
          '$cleanupWorkerRevokedMarkerFileName';

      final startedAt = DateTime.now();
      // A single origin for every deadline below: the worker's own
      // marker-creation deadline, claim deadline and ack deadline, all
      // carried through the payload as Unix epoch milliseconds (UTC, so
      // both processes compare them against the same origin regardless of
      // local time zone), and this class's own poll deadlines further
      // down. The marker-creation deadline is kept a fixed safety margin
      // ahead of this class's Phase 1 poll deadline so its poll interval
      // always has time to observe a marker the worker created in time;
      // the claim deadline matches this class's own Phase 1 poll deadline
      // exactly, since the claim itself, not either side's clock, is what
      // decides who wins once a marker exists; the ack deadline matches
      // this class's own Phase 2 poll deadline the same way.
      final markerDeadlineUnixMs =
          startedAt.toUtc().millisecondsSinceEpoch +
          (_startupTimeout - _markerDeadlineSafetyMargin).inMilliseconds;
      final cliDeadline = startedAt.add(_startupTimeout);
      final claimDeadlineUnixMs = cliDeadline.toUtc().millisecondsSinceEpoch;
      final ackDeadline = cliDeadline.add(cleanupWorkerAckTimeout);
      final ackDeadlineUnixMs = ackDeadline.toUtc().millisecondsSinceEpoch;
      final effectivePayload = Map<String, Object?>.from(payload)
        ..['markerDeadlineUnixMs'] = markerDeadlineUnixMs
        ..['claimDeadlineUnixMs'] = claimDeadlineUnixMs
        ..['ackDeadlineUnixMs'] = ackDeadlineUnixMs;

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

      // The Phase 1 claim succeeded, but that alone is not proof the
      // worker is still alive to ever arm deletion: it may have crashed,
      // or been killed, between creating its ready marker and now. Nothing
      // is reported as scheduled until this class actually observes the
      // worker's own Phase 2 arm marker, or loses its own competing revoke
      // attempt to a worker that armed just in time.
      final armed = await pollForArm(
        armedMarkerPath: armedMarkerPath,
        deadline: ackDeadline,
        pollInterval: cleanupWorkerReadyPollInterval,
        now: DateTime.now,
      );
      if (!armed) {
        final revoked = tryRevokeAcceptedMarker(
          acceptedMarkerPath,
          revokedMarkerPath,
        );
        if (revoked) {
          throw CliCleanupWorkerStartFailure(
            'The cleanup worker won the initial claim over its ready '
            'marker but never armed deletion within '
            '${cleanupWorkerAckTimeout.inSeconds}s afterwards, so its '
            'claim has been revoked.',
          );
        }
        // Lost the revoke race: the worker's own rename to the armed
        // marker won between the last poll above and this attempt. Falls
        // through to report success below, the same as an armed marker
        // pollForArm itself had observed directly.
      }

      // The worker now owns deleting the given paths, and its own private
      // directory, once the watched process exits. Nothing further here
      // needs, or may touch, that directory; see the class doc comment for
      // why removing it here would race the worker's own use of it.
      return;
    } on CliCleanupWorkerStartFailure catch (e) {
      startFailure = e;
    } on io.FileSystemException catch (e) {
      // An unexpected rename failure from tryClaimReadyMarker or
      // tryRevokeAcceptedMarker: not folded into an ordinary lost claim by
      // either of those (see their own doc comments), and not swallowed
      // here either. Surfaced as the same typed failure every other
      // startup problem is, with the underlying exception's own detail
      // kept in the message.
      startFailure = CliCleanupWorkerStartFailure(
        'Could not start the cleanup worker: an unexpected failure '
        'renaming one of its protocol markers: $e',
      );
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
