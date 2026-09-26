/// The cleanup worker's bootstrap script content, and (Windows-only) the
/// real worker's behaviour against a real process and a real file: it
/// deletes nothing while the parent it was told to watch is still alive,
/// and deletes the given path once that parent exits, including when the
/// process that launched it has itself already exited, which is the whole
/// point of a cleanup worker. Also covers the command-line-injection,
/// non-ASCII-payload, predictable-temp-name and leftover-artifact findings:
/// no path ever appears on the `cmd.exe` command line, the payload travels
/// as an environment variable rather than a file a pre-BOM-unaware
/// `Get-Content` could misread, the ready marker lives inside a privately
/// and exclusively created temporary directory, and the launcher removes
/// that directory on every outcome.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;

import 'package:modular_cli_sdk/modular_cli_sdk.dart';
// Round 5 finding 5: cleanupWorkerCmdCommandLine and
// cleanupWorkerEncodedBootstrapScript are implementation details of how the
// worker is launched, not part of the public API, so they are not exported
// from the public barrel above. This test still needs them, to check the
// command line and the encoded script directly, so it reaches them through
// the src path instead. Round 6 finding 1's protocol-state filenames and its
// two pure claim-attempt helpers are the same kind of implementation detail,
// reached the same way. Round 7's Phase 2 protocol-state filenames and its
// own pure attempt/poll helpers are reached the same way too.
import 'package:modular_cli_sdk/src/plugins/installation/cli_process_launcher.dart'
    show
        RevokeOrArmOutcome,
        cleanupWorkerAbandonedMarkerFileName,
        cleanupWorkerAcceptedMarkerFileName,
        cleanupWorkerArmedMarkerFileName,
        cleanupWorkerCmdCommandLine,
        cleanupWorkerEncodedBootstrapScript,
        cleanupWorkerReadyMarkerFileName,
        cleanupWorkerRevokedMarkerFileName,
        pollForArm,
        pollForClaim,
        pollForRevokeOrArm,
        tryClaimReadyMarker,
        tryRevokeAcceptedMarker;
import 'package:test/test.dart';

/// Every directory directly under the system temp directory whose name
/// starts with the private-directory prefix [IoCliProcessLauncher] uses for
/// the cleanup worker's ready marker. Used to assert nothing is left behind,
/// on both a successful run and a startup failure.
Set<String> _existingCleanupPrivateDirs() => io.Directory.systemTemp
    .listSync()
    .whereType<io.Directory>()
    .map((d) => d.path)
    .where(
      (path) =>
          path.split(io.Platform.pathSeparator).last.startsWith('cli_cleanup_'),
    )
    .toSet();

// Round 9 finding 2: a test used to race the real, unmodified worker for
// the exact same accepted-to-armed rename it was trying to lock out from
// under it, relying on out-running the worker's own 50ms poll cadence with
// a tight existsSync() poll of its own. That race could be lost: the
// worker could win the rename before, or between, this test's own
// existsSync() check and its openSync(FileMode.write) call, and
// FileMode.write on an already-renamed accepted marker silently recreates
// it as an empty file rather than failing, masking the loss instead of
// surfacing it. [_armBarrierScript] closes the race instead of trying to
// out-run it: a copy of the real script, modified to wait for a named
// release marker immediately before ever attempting that rename, so a
// test can lock the accepted marker first and only then tell the worker
// it may contest it.
const _armBarrierReleaseMarkerFileName = 'release-arm-for-test';

String _buildArmBarrierScript() {
  const anchor =
      r'$armed = Complete-Rename $AcceptedMarkerPath $ArmedMarkerPath';
  final barrier =
      '\$ReleaseArmMarkerPath = Join-Path \$PrivateDir '
      "'$_armBarrierReleaseMarkerFileName'\n"
      'while (-not (Test-Path -LiteralPath \$ReleaseArmMarkerPath)) {\n'
      '    Start-Sleep -Milliseconds 20\n'
      '}\n'
      '$anchor';
  final script = cleanupWorkerBootstrapScript.replaceFirst(anchor, barrier);
  if (script == cleanupWorkerBootstrapScript) {
    throw StateError(
      'the arm-rename anchor must actually match cleanupWorkerBootstrapScript',
    );
  }
  return script;
}

final String _armBarrierScript = _buildArmBarrierScript();

final String _armBarrierEncodedScript = _encodeScriptForPowerShell(
  _armBarrierScript,
);

/// The path a test releases, once its own lock on the accepted marker is
/// installed, to let a worker running [_armBarrierScript] finally attempt
/// its arm rename.
String _armBarrierReleaseMarkerPath(String privateDirPath) =>
    '$privateDirPath${io.Platform.pathSeparator}'
    '$_armBarrierReleaseMarkerFileName';

/// An [IoCliProcessLauncher] whose worker script is [_armBarrierScript]
/// rather than the real, unmodified one: the same script a real run
/// launches, except for its added wait for
/// [_armBarrierReleaseMarkerFileName] immediately before the arm rename.
/// Production code never overrides [encodedBootstrapScript]; this exists
/// purely as a test seam (see its own doc comment).
class _ArmBarrierLauncher extends IoCliProcessLauncher {
  _ArmBarrierLauncher({
    required super.ackTimeout,
    required super.revokeTimeout,
  });

  @override
  String encodedBootstrapScript() => _armBarrierEncodedScript;
}

// Round 9 finding 3: a fixed parent lifetime (a plain `Start-Sleep -Seconds
// N`) made the contrast these tests draw nondeterministic, since worker
// readiness can legitimately take up to the full 20s these tests already
// allow it: a slow readiness poll could let the fixed-lifetime parent exit
// on its own, for entirely unrelated reasons, before a test ever reached
// the assertions that depend on it still being alive. [_startReleasableParent]
// replaces the fixed sleep with an explicit release signal a test controls
// directly, so "the parent is still alive" is a fact this test holds, not
// one a fixed duration merely hoped would still be true.
Future<io.Process> _startReleasableParent(String releaseMarkerPath) =>
    io.Process.start('powershell', [
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      "while (-not (Test-Path -LiteralPath '$releaseMarkerPath')) { "
          'Start-Sleep -Milliseconds 50 }',
    ]);

/// The deadline [_claimReadyMarkerForTest] gives its own retrying claim.
const _claimReadyMarkerForTestDeadline = Duration(seconds: 5);

/// The poll interval [_claimReadyMarkerForTest] retries on.
const _claimReadyMarkerForTestPollInterval = Duration(milliseconds: 20);

/// Simulates the CLI's own Phase 1 claim of a ready marker a real worker
/// process just created, through [pollForClaim], the same retrying call
/// [IoCliProcessLauncher.startCleanupWorker] itself makes, rather than the
/// bare, single-attempt [tryClaimReadyMarker].
///
/// A worker's ready marker is a file another process only just created,
/// exactly the situation [tryClaimReadyMarker]'s own doc comment already
/// names as able to briefly see a real, unexpected Windows sharing
/// violation (observed in practice from a freshly created file getting a
/// transient extra handle, such as from real-time antivirus scanning). A
/// single unretried attempt asserted to succeed made a test flaky on
/// exactly that transient condition; this rides it out on the same bounded
/// retry production code already relies on, rather than assuming the very
/// first attempt always wins.
Future<bool> _claimReadyMarkerForTest(String readyPath, String acceptedPath) =>
    pollForClaim(
      readyMarkerPath: readyPath,
      acceptedMarkerPath: acceptedPath,
      deadline: DateTime.now().add(_claimReadyMarkerForTestDeadline),
      pollInterval: _claimReadyMarkerForTestPollInterval,
      now: DateTime.now,
    );

void main() {
  group('cleanupWorkerBootstrapScript', () {
    // Fixed and never interpolated: every piece of run-specific data is
    // read once from a JSON payload carried by an environment variable
    // instead, so nothing here needs to escape a path, and nothing here is
    // built from a command-line argument that a shell could re-parse.
    test('reads its payload from an environment variable, not a file', () {
      expect(cleanupWorkerBootstrapScript, contains('ConvertFrom-Json'));
      expect(
        cleanupWorkerBootstrapScript,
        contains(r'$env:' + cleanupWorkerPayloadEnvVar),
      );
      // No file read: an environment variable is inherited by the child
      // through Windows' native, Unicode-safe environment block, never
      // through a UTF-8-without-BOM file a PowerShell 5.1 Get-Content call
      // would decode as the system ANSI code page and silently corrupt.
      expect(cleanupWorkerBootstrapScript, isNot(contains('Get-Content')));
    });

    test('signals readiness through a marker file named by an environment '
        'variable, created without recreating a missing parent directory', () {
      expect(
        cleanupWorkerBootstrapScript,
        contains(r'$env:' + cleanupWorkerReadyMarkerPathEnvVar),
      );
      // Round 5 finding 2: New-Item -Force recreates a private directory
      // the CLI already deleted after giving up waiting, letting a late
      // worker silently schedule a deletion the CLI already reported as
      // failed. File.Open with CreateNew fails instead, both when the
      // directory is gone and when the marker somehow already exists.
      expect(
        cleanupWorkerBootstrapScript,
        contains('[System.IO.FileMode]::CreateNew'),
      );
      expect(cleanupWorkerBootstrapScript, isNot(contains('New-Item')));
      expect(cleanupWorkerBootstrapScript, isNot(contains('-Force')));
    });

    // Round 6 finding 2: PowerShell 5.1's own $parent.Handle property-getter
    // syntax has been observed to return $null instead of throwing for an
    // access-denied process, even under $ErrorActionPreference = 'Stop'.
    // get_Handle(), the explicit method-call form of the same accessor, is
    // what the worker uses instead, precisely so a failure to retain the
    // handle cannot be missed this way.
    test('retains a handle on the parent process, via the explicit '
        'get_Handle() accessor rather than the Handle property, before '
        'signalling ready', () {
      expect(cleanupWorkerBootstrapScript, contains('GetProcessById'));
      expect(cleanupWorkerBootstrapScript, contains(r'$parent.get_Handle()'));
      expect(cleanupWorkerBootstrapScript, isNot(contains(r'$parent.Handle')));
      final markerIndex = cleanupWorkerBootstrapScript.indexOf(
        '[System.IO.FileMode]::CreateNew',
      );
      final handleIndex = cleanupWorkerBootstrapScript.indexOf(
        r'$parent.get_Handle()',
      );
      expect(handleIndex, greaterThanOrEqualTo(0));
      expect(markerIndex, greaterThan(handleIndex));
    });

    // Round 6 finding 2: get_Handle() alone is not enough, since it is the
    // same underlying accessor that can silently return $null; the worker
    // must also explicitly reject a null or zero handle itself, before the
    // ready marker exists, rather than trust a value that a null handle
    // would let through unnoticed.
    test('explicitly rejects a null or zero handle, before the ready marker '
        'is created, rather than trusting whatever get_Handle() returned', () {
      expect(cleanupWorkerBootstrapScript, contains('[IntPtr]::Zero'));
      expect(cleanupWorkerBootstrapScript, contains(r'$null -eq $handle'));
      final validationIndex = cleanupWorkerBootstrapScript.indexOf(
        '[IntPtr]::Zero',
      );
      final markerIndex = cleanupWorkerBootstrapScript.indexOf(
        '[System.IO.FileMode]::CreateNew',
      );
      expect(validationIndex, greaterThanOrEqualTo(0));
      expect(markerIndex, greaterThan(validationIndex));
    });

    // Round 5 finding 1: GetProcessById throwing System.ArgumentException
    // means no such process exists, which is genuinely "the parent already
    // exited" and safe to treat as $parent = $null. Any other failure
    // retaining a handle on a process that does exist (most notably,
    // access denied on .Handle itself for a protected process) must not be
    // folded into that same "already exited" outcome: it has to stop the
    // worker before the ready marker is created, so the CLI sees no marker
    // in time and reports cleanup-start-failed instead of a worker that
    // silently is not actually holding what it needs.
    test('catches only ArgumentException around GetProcessById, so a '
        'different failure retaining the handle is not folded into '
        '"parent already exited"', () {
      expect(
        cleanupWorkerBootstrapScript,
        contains('catch [System.ArgumentException]'),
      );
      final catchIndex = cleanupWorkerBootstrapScript.indexOf(
        'catch [System.ArgumentException]',
      );
      final handleIndex = cleanupWorkerBootstrapScript.indexOf(
        r'$parent.get_Handle()',
      );
      expect(catchIndex, greaterThanOrEqualTo(0));
      expect(handleIndex, greaterThanOrEqualTo(0));
      // The handle access sits after the typed catch block closes, not
      // inside a try that would catch a Win32Exception from it too.
      expect(handleIndex, greaterThan(catchIndex));
    });

    // Round 5 finding 2: closes the race where startCleanupWorker has
    // already given up waiting for a marker and deleted the private
    // directory it created. Past this deadline (computed by the CLI from
    // its own startup timeout and safety margin, carried in the payload)
    // the worker refuses to create the marker and exits, deleting nothing,
    // rather than silently scheduling a deletion the CLI already reported
    // as failed.
    test(
      'refuses to create the marker past a deadline read from the payload',
      () {
        expect(cleanupWorkerBootstrapScript, contains('markerDeadlineUnixMs'));
        expect(
          cleanupWorkerBootstrapScript,
          contains('ToUnixTimeMilliseconds'),
        );
        final deadlineCheckIndex = cleanupWorkerBootstrapScript.indexOf(
          'markerDeadlineUnixMs',
        );
        final markerIndex = cleanupWorkerBootstrapScript.indexOf(
          '[System.IO.FileMode]::CreateNew',
        );
        expect(deadlineCheckIndex, greaterThanOrEqualTo(0));
        expect(markerIndex, greaterThan(deadlineCheckIndex));
      },
    );

    // Round 6 finding 1: an absolute deadline alone does not prevent the
    // race where the CLI is suspended right up to its own deadline, wakes
    // up after it, reports failure and deletes the private directory,
    // while a worker that created its marker in time goes on to delete the
    // real target regardless. The protocol below decides that question
    // with a single atomic rename instead of either side's clock: exactly
    // one of the CLI (to accepted) and the worker itself (to abandoned) can
    // ever win, since a rename of a source path that no longer exists
    // fails.
    test('reads its own copy of the CLI\'s absolute claim deadline from the '
        'payload, separately from the marker-creation deadline', () {
      expect(cleanupWorkerBootstrapScript, contains('claimDeadlineUnixMs'));
      expect(cleanupWorkerBootstrapScript, contains('markerDeadlineUnixMs'));
    });

    test('computes the accepted and abandoned marker paths as siblings of the '
        'ready marker, named by the protocol\'s own state constants', () {
      expect(
        cleanupWorkerBootstrapScript,
        contains(
          "Join-Path \$PrivateDir '$cleanupWorkerAcceptedMarkerFileName'",
        ),
      );
      expect(
        cleanupWorkerBootstrapScript,
        contains(
          "Join-Path \$PrivateDir '$cleanupWorkerAbandonedMarkerFileName'",
        ),
      );
    });

    test('claims abandonment through an atomic rename, only after the ready '
        'marker was created, not instead of waiting for the CLI to claim it '
        'first', () {
      expect(cleanupWorkerBootstrapScript, contains('[System.IO.File]::Move('));
      final markerIndex = cleanupWorkerBootstrapScript.indexOf(
        '[System.IO.FileMode]::CreateNew',
      );
      // The rename itself lives inside the shared Complete-Rename helper
      // (defined once, ahead of everything that calls it); what has to
      // come after the ready marker is created is the abandon call site,
      // not the helper's own definition.
      final abandonCallIndex = cleanupWorkerBootstrapScript.indexOf(
        'Complete-Rename \$ReadyMarkerPath \$AbandonedMarkerPath',
      );
      expect(abandonCallIndex, greaterThanOrEqualTo(0));
      expect(abandonCallIndex, greaterThan(markerIndex));
    });

    // Round 7 finding 1: a dead worker's ready marker still being claimed
    // by the CLI must not, on its own, arm anything. Merely observing that
    // the accepted marker exists is no longer enough; the worker has to
    // actually win its own atomic rename of it to the armed marker first.
    test('arms deletion only by winning an atomic rename of the accepted '
        'marker to the armed marker, never merely by observing that the '
        'accepted marker exists', () {
      expect(
        cleanupWorkerBootstrapScript,
        contains(
          r'$armed = Complete-Rename $AcceptedMarkerPath $ArmedMarkerPath',
        ),
      );
      expect(
        cleanupWorkerBootstrapScript,
        isNot(contains(r'$armed = Test-Path')),
      );
    });

    test('computes the armed marker path as a sibling of the ready marker, '
        'named by the protocol\'s own state constant', () {
      expect(
        cleanupWorkerBootstrapScript,
        contains("Join-Path \$PrivateDir '$cleanupWorkerArmedMarkerFileName'"),
      );
    });

    // Round 7 finding 2: an unexpected failure renaming either the ready
    // marker to abandoned or the accepted marker to armed (a sharing
    // violation being the concrete case reported) must never be swallowed
    // by an empty catch. There is no bare `catch { }` anywhere in the
    // script; every catch either narrows to the legitimate-loss exception
    // type or does something (retry, or record a failure and exit) in its
    // body.
    test('never swallows a rename failure in a bare empty catch', () {
      expect(
        RegExp(r'catch\s*\{\s*\}').hasMatch(cleanupWorkerBootstrapScript),
        isFalse,
      );
    });

    // Both the abandon rename and the arm rename retry through the same
    // shared Complete-Rename helper (kept as one definition specifically so
    // the retry and typed-loss logic exists exactly once, short enough to
    // stay well under cmd.exe's command-line limit even after Phase 2 grew
    // the script). This checks the helper itself retries an unexpected
    // failure rather than giving up the moment the first attempt fails,
    // distinguishing that from the legitimate loss of the source already
    // being gone, and that both call sites actually go through it.
    //
    // Round 8 finding 2: there is no longer any deadline the worker gives up
    // at while a claimable marker still exists; deciding whether the worker
    // ever wins is left entirely to IoCliProcessLauncher's own side of the
    // race (see pollForRevokeOrArm), so the worker's own copy of an ack
    // deadline (`ackDeadlineUnixMs`) no longer exists at all, in this helper
    // or anywhere else in the script.
    test('retries an unexpected rename failure on the same poll interval, with '
        'no deadline of its own, through the one shared helper both the '
        'abandon and the arm rename call, rather than giving up the moment '
        'the first attempt fails or after any fixed amount of retrying', () {
      final functionIndex = cleanupWorkerBootstrapScript.indexOf(
        'function Complete-Rename',
      );
      final typedCatchIndex = cleanupWorkerBootstrapScript.indexOf(
        'catch [System.IO.FileNotFoundException]',
        functionIndex,
      );
      final abandonCallIndex = cleanupWorkerBootstrapScript.indexOf(
        'Complete-Rename \$ReadyMarkerPath \$AbandonedMarkerPath',
      );
      final armCallIndex = cleanupWorkerBootstrapScript.indexOf(
        'Complete-Rename \$AcceptedMarkerPath \$ArmedMarkerPath',
      );
      expect(functionIndex, greaterThanOrEqualTo(0));
      expect(typedCatchIndex, greaterThan(functionIndex));
      expect(abandonCallIndex, greaterThan(functionIndex));
      expect(armCallIndex, greaterThan(functionIndex));
      expect(
        cleanupWorkerBootstrapScript,
        isNot(contains('ackDeadlineUnixMs')),
        reason:
            'the worker no longer gives up on a retried rename at all, '
            'so it has no use for a copy of the ack deadline',
      );
    });

    // Round 8 finding 3: the failed marker used to be written, best effort,
    // from within a nested catch when a retried rename never succeeded
    // before a deadline the worker no longer has. With no such deadline to
    // give up at, there is nothing left to record a failure from, so the
    // marker, its path variable and the nested catch that wrote it are gone
    // entirely, not merely unused.
    test('no longer declares, or writes, a failed-marker path: there is no '
        'deadline left for the worker to give up at and record one from', () {
      expect(cleanupWorkerBootstrapScript, isNot(contains('FailedMarkerPath')));
      expect(cleanupWorkerBootstrapScript, isNot(contains("'failed'")));
    });

    // Round 7 finding 3: the worker must wait for the parent with no time
    // limit at all once armed, not a bounded wait that can give up while
    // the parent is merely slow to exit. There is no timeoutMs field left
    // in the payload for a bound to even come from.
    test('waits for the parent with the parameterless, unbounded '
        'WaitForExit(), never the bounded overload, and reads no timeoutMs '
        'from the payload at all', () {
      expect(cleanupWorkerBootstrapScript, contains(r'$parent.WaitForExit()'));
      expect(
        cleanupWorkerBootstrapScript,
        isNot(contains(r'$parent.WaitForExit($timeoutMs)')),
      );
      expect(cleanupWorkerBootstrapScript, isNot(contains('timeoutMs')));
    });

    // Round 8 finding 2: the CLI no longer carries an ack deadline to the
    // worker at all (there is no more `ackDeadlineUnixMs` in the payload it
    // sends); only the two deadlines the worker itself still acts on, the
    // marker-creation deadline and the claim deadline, are read from it.
    test('reads the marker-creation and claim deadlines from the payload, but '
        'no ack deadline: deciding whether the worker ever arms in time is '
        'entirely IoCliProcessLauncher\'s own concern', () {
      expect(cleanupWorkerBootstrapScript, contains('markerDeadlineUnixMs'));
      expect(cleanupWorkerBootstrapScript, contains('claimDeadlineUnixMs'));
      expect(
        cleanupWorkerBootstrapScript,
        isNot(contains('ackDeadlineUnixMs')),
      );
    });

    test('deletes its own private directory only once armed, after deleting '
        'the target paths, so that responsibility never depends on the CLI '
        'having already removed it before the worker could observe the '
        'claim it won', () {
      final armedIndex = cleanupWorkerBootstrapScript.indexOf(r'if ($armed) {');
      final removeTargetIndex = cleanupWorkerBootstrapScript.indexOf(
        r'Remove-WithRetry $path',
      );
      final removePrivateDirIndex = cleanupWorkerBootstrapScript.indexOf(
        r'Remove-WithRetry $PrivateDir -Recurse',
      );
      expect(armedIndex, greaterThanOrEqualTo(0));
      expect(removeTargetIndex, greaterThan(armedIndex));
      expect(removePrivateDirIndex, greaterThan(removeTargetIndex));
    });

    test('waits for the parent to exit before deleting anything', () {
      expect(cleanupWorkerBootstrapScript, contains('WaitForExit'));
      final waitIndex = cleanupWorkerBootstrapScript.indexOf('WaitForExit');
      final removeTargetIndex = cleanupWorkerBootstrapScript.indexOf(
        r'Remove-WithRetry $path',
      );
      expect(removeTargetIndex, greaterThan(waitIndex));
    });

    // The final deletion steps used to be the one place in the script that
    // never rode out an unexpected failure the way every marker rename
    // already does: an unhandled sharing violation there killed the worker
    // (exit code 1) before the target was ever removed, exactly the
    // intermittent failure this test root-causes. Remove-WithRetry closes
    // that gap the same way Complete-Rename already does for renames.
    test('retries deleting the target paths and the private directory the '
        'same way it already retries a marker rename, but still stops '
        'once a path is legitimately already gone', () {
      expect(
        cleanupWorkerBootstrapScript,
        contains('function Remove-WithRetry'),
      );
      expect(
        cleanupWorkerBootstrapScript,
        contains('catch [System.Management.Automation.ItemNotFoundException]'),
      );
      expect(
        cleanupWorkerBootstrapScript,
        contains('Start-Sleep -Milliseconds 50'),
      );
      expect(
        cleanupWorkerBootstrapScript,
        isNot(contains(r'Remove-Item -LiteralPath $path')),
      );
      expect(
        cleanupWorkerBootstrapScript,
        isNot(contains(r'Remove-Item -LiteralPath $PrivateDir -Recurse')),
      );
    });

    test('deletes with -LiteralPath under a Stop error action', () {
      expect(
        cleanupWorkerBootstrapScript,
        contains("\$ErrorActionPreference = 'Stop'"),
      );
      expect(
        cleanupWorkerBootstrapScript,
        contains('Remove-Item -LiteralPath'),
      );
    });
  });

  // Round 6 finding 1: these are the same two pure, synchronous primitives
  // IoCliProcessLauncher.startCleanupWorker itself calls to decide the
  // accept/abandon claim, exercised here directly against real files in a
  // real temporary directory (no real subprocess, no real clock) so the two
  // scenarios the coordinator asked for, a worker winning the claim and a
  // worker losing it, are deterministic rather than dependent on real
  // process-start timing.
  group('tryClaimReadyMarker', () {
    late io.Directory tempDir;

    setUp(() {
      tempDir = io.Directory.systemTemp.createTempSync('claim_unit_test_');
    });

    tearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    test('renames the ready marker to accepted and returns true when it '
        'exists', () {
      final readyPath = '${tempDir.path}${io.Platform.pathSeparator}ready';
      final acceptedPath =
          '${tempDir.path}${io.Platform.pathSeparator}accepted';
      io.File(readyPath).createSync();

      expect(tryClaimReadyMarker(readyPath, acceptedPath), isTrue);
      expect(io.File(acceptedPath).existsSync(), isTrue);
      expect(io.File(readyPath).existsSync(), isFalse);
    });

    test('returns false, creating nothing, when the ready marker was never '
        'created', () {
      final readyPath = '${tempDir.path}${io.Platform.pathSeparator}ready';
      final acceptedPath =
          '${tempDir.path}${io.Platform.pathSeparator}accepted';

      expect(tryClaimReadyMarker(readyPath, acceptedPath), isFalse);
      expect(io.File(acceptedPath).existsSync(), isFalse);
    });

    test('loses the claim when the worker already renamed the ready marker '
        'to abandoned first', () {
      final readyPath = '${tempDir.path}${io.Platform.pathSeparator}ready';
      final acceptedPath =
          '${tempDir.path}${io.Platform.pathSeparator}accepted';
      final abandonedPath =
          '${tempDir.path}${io.Platform.pathSeparator}abandoned';
      io.File(readyPath).createSync();
      // Simulates the worker's own winning claim of abandonment: the
      // exact rename the bootstrap script performs at its own deadline.
      io.File(readyPath).renameSync(abandonedPath);

      expect(tryClaimReadyMarker(readyPath, acceptedPath), isFalse);
      expect(io.File(acceptedPath).existsSync(), isFalse);
      expect(io.File(abandonedPath).existsSync(), isTrue);
    });

    // Round 7 finding 2: a rename that fails for a reason other than its
    // source already being gone (here, another handle keeping the ready
    // marker open, provoking a real Windows sharing violation) must not
    // be folded into an ordinary lost claim. This is the exact primitive
    // the worker's own retried abandon rename, and IoCliProcessLauncher's
    // own claim rename, both depend on to tell "the other side genuinely
    // won" apart from "this rename never actually ran to completion".
    test(
      'propagates an unexpected rename failure instead of treating it as '
      'a lost claim',
      () {
        final readyPath = '${tempDir.path}${io.Platform.pathSeparator}ready';
        final acceptedPath =
            '${tempDir.path}${io.Platform.pathSeparator}accepted';
        io.File(readyPath).createSync();
        final lock = io.File(readyPath).openSync(mode: io.FileMode.write);

        try {
          expect(
            () => tryClaimReadyMarker(readyPath, acceptedPath),
            throwsA(isA<io.FileSystemException>()),
          );
          expect(io.File(acceptedPath).existsSync(), isFalse);
          expect(io.File(readyPath).existsSync(), isTrue);
        } finally {
          lock.closeSync();
        }
      },
      skip: io.Platform.isWindows
          ? false
          : 'provokes a real Windows sharing violation',
    );

    // Round 7 finding 2: the concrete "failed abandonment followed by a
    // late CLI claim" scenario. Under the old empty catch, the worker
    // would give up the instant its own abandon rename failed for any
    // reason, leaving the ready marker sitting there for a claim nobody
    // was left to arm. The fix retries instead; this proves the primitive
    // that retry depends on actually behaves the way the retry assumes:
    // once whatever caused the unexpected failure clears, the ready
    // marker the worker never actually managed to remove is still exactly
    // as claimable as if the worker had not attempted to abandon it at
    // all.
    test(
      'a claim that arrives only after an unexpected rename failure has '
      'cleared still succeeds, exactly what a worker retrying its own '
      'failed abandon rename, instead of giving up on it silently, relies '
      'on to notice a late CLI claim rather than a permanent loss',
      () {
        final readyPath = '${tempDir.path}${io.Platform.pathSeparator}ready';
        final acceptedPath =
            '${tempDir.path}${io.Platform.pathSeparator}accepted';
        final abandonedPath =
            '${tempDir.path}${io.Platform.pathSeparator}abandoned';
        io.File(readyPath).createSync();
        final lock = io.File(readyPath).openSync(mode: io.FileMode.write);

        // The worker's own retried abandon rename, mid-retry: fails with
        // the same unexpected error tryClaimReadyMarker itself must
        // propagate rather than swallow, while the lock is held.
        expect(
          () => io.File(readyPath).renameSync(abandonedPath),
          throwsA(isA<io.FileSystemException>()),
        );
        expect(io.File(readyPath).existsSync(), isTrue);

        lock.closeSync();

        // The "late" CLI claim: the ready marker is still genuinely there,
        // so it succeeds.
        expect(tryClaimReadyMarker(readyPath, acceptedPath), isTrue);
        expect(io.File(acceptedPath).existsSync(), isTrue);
        expect(io.File(abandonedPath).existsSync(), isFalse);
      },
      skip: io.Platform.isWindows
          ? false
          : 'provokes a real Windows sharing violation',
    );
  });

  // Round 7 finding 1: the same pure, synchronous primitive
  // IoCliProcessLauncher.startCleanupWorker itself calls, on the CLI's own
  // side of the Phase 2 race, to decide whether it may revoke a claim the
  // worker never armed. Exercised directly against real files for the same
  // determinism reason tryClaimReadyMarker is.
  group('tryRevokeAcceptedMarker', () {
    late io.Directory tempDir;

    setUp(() {
      tempDir = io.Directory.systemTemp.createTempSync('revoke_unit_test_');
    });

    tearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    test('renames the accepted marker to revoked and returns true when it '
        'exists', () {
      final acceptedPath =
          '${tempDir.path}${io.Platform.pathSeparator}accepted';
      final revokedPath =
          '${tempDir.path}${io.Platform.pathSeparator}$cleanupWorkerRevokedMarkerFileName';
      io.File(acceptedPath).createSync();

      expect(tryRevokeAcceptedMarker(acceptedPath, revokedPath), isTrue);
      expect(io.File(revokedPath).existsSync(), isTrue);
      expect(io.File(acceptedPath).existsSync(), isFalse);
    });

    test('returns false, creating nothing, when the accepted marker does not '
        'exist', () {
      final acceptedPath =
          '${tempDir.path}${io.Platform.pathSeparator}accepted';
      final revokedPath =
          '${tempDir.path}${io.Platform.pathSeparator}$cleanupWorkerRevokedMarkerFileName';

      expect(tryRevokeAcceptedMarker(acceptedPath, revokedPath), isFalse);
      expect(io.File(revokedPath).existsSync(), isFalse);
    });

    // Revoke-vs-arm race, direction 1: the worker wins by renaming
    // accepted to armed first. The CLI's own revoke attempt, arriving
    // after, must lose cleanly.
    test('loses the race when the worker already renamed the accepted marker '
        'to armed first', () {
      final acceptedPath =
          '${tempDir.path}${io.Platform.pathSeparator}accepted';
      final armedPath = '${tempDir.path}${io.Platform.pathSeparator}armed';
      final revokedPath =
          '${tempDir.path}${io.Platform.pathSeparator}$cleanupWorkerRevokedMarkerFileName';
      io.File(acceptedPath).createSync();
      // Simulates the worker's own winning arm rename: the exact rename
      // cleanupWorkerBootstrapScript performs once it observes accepted.
      io.File(acceptedPath).renameSync(armedPath);

      expect(tryRevokeAcceptedMarker(acceptedPath, revokedPath), isFalse);
      expect(io.File(revokedPath).existsSync(), isFalse);
      expect(io.File(armedPath).existsSync(), isTrue);
    });

    // Revoke-vs-arm race, direction 2: the CLI wins by renaming accepted
    // to revoked first. The worker's own later arm rename, arriving after,
    // must lose cleanly (a legitimate "source not found" loss, exactly
    // what tells the worker to exit without deleting).
    test('wins the race before the worker gets a chance to arm, so a late '
        'arm rename attempt afterwards fails because the source is already '
        'gone', () {
      final acceptedPath =
          '${tempDir.path}${io.Platform.pathSeparator}accepted';
      final armedPath = '${tempDir.path}${io.Platform.pathSeparator}armed';
      final revokedPath =
          '${tempDir.path}${io.Platform.pathSeparator}$cleanupWorkerRevokedMarkerFileName';
      io.File(acceptedPath).createSync();

      expect(tryRevokeAcceptedMarker(acceptedPath, revokedPath), isTrue);
      expect(io.File(revokedPath).existsSync(), isTrue);

      // The worker's own late arm attempt, using the exact same
      // primitive the bootstrap script relies on.
      expect(
        () => io.File(acceptedPath).renameSync(armedPath),
        throwsA(isA<io.FileSystemException>()),
      );
      expect(io.File(armedPath).existsSync(), isFalse);
    });

    test(
      'propagates an unexpected rename failure instead of treating it as '
      'a lost revoke',
      () {
        final acceptedPath =
            '${tempDir.path}${io.Platform.pathSeparator}accepted';
        final revokedPath =
            '${tempDir.path}${io.Platform.pathSeparator}$cleanupWorkerRevokedMarkerFileName';
        io.File(acceptedPath).createSync();
        final lock = io.File(acceptedPath).openSync(mode: io.FileMode.write);

        try {
          expect(
            () => tryRevokeAcceptedMarker(acceptedPath, revokedPath),
            throwsA(isA<io.FileSystemException>()),
          );
          expect(io.File(revokedPath).existsSync(), isFalse);
        } finally {
          lock.closeSync();
        }
      },
      skip: io.Platform.isWindows
          ? false
          : 'provokes a real Windows sharing violation',
    );
  });

  group('pollForArm', () {
    late io.Directory tempDir;

    setUp(() {
      tempDir = io.Directory.systemTemp.createTempSync('poll_arm_test_');
    });

    tearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    test('observes an armed marker the worker already created, even on its '
        'very first check', () async {
      final armedPath = '${tempDir.path}${io.Platform.pathSeparator}armed';
      io.File(armedPath).createSync();

      final armed = await pollForArm(
        armedMarkerPath: armedPath,
        deadline: DateTime.now().add(const Duration(milliseconds: 30)),
        pollInterval: const Duration(milliseconds: 5),
        now: DateTime.now,
      );

      expect(armed, isTrue);
    });

    test(
      'gives up once the deadline passes when the armed marker never '
      'appears, exactly the case a crashed or killed worker leaves behind',
      () async {
        final armedPath = '${tempDir.path}${io.Platform.pathSeparator}armed';

        final armed = await pollForArm(
          armedMarkerPath: armedPath,
          deadline: DateTime.now().add(const Duration(milliseconds: 30)),
          pollInterval: const Duration(milliseconds: 5),
          now: DateTime.now,
        );

        expect(armed, isFalse);
      },
    );

    test('never creates the armed marker itself, only observes it', () async {
      final armedPath = '${tempDir.path}${io.Platform.pathSeparator}armed';

      await pollForArm(
        armedMarkerPath: armedPath,
        deadline: DateTime.now().add(const Duration(milliseconds: 20)),
        pollInterval: const Duration(milliseconds: 5),
        now: DateTime.now,
      );

      expect(io.File(armedPath).existsSync(), isFalse);
    });
  });

  // Round 8 finding 1: the seam IoCliProcessLauncher.startCleanupWorker
  // itself calls once pollForArm has given up waiting, to decide the Phase 2
  // race by retrying its own revoke rename rather than reporting failure (and
  // removing the private directory) on a single failed attempt that the
  // worker might still win a moment later.
  group('pollForRevokeOrArm', () {
    late io.Directory tempDir;

    setUp(() {
      tempDir = io.Directory.systemTemp.createTempSync('poll_revoke_test_');
    });

    tearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    test(
      'observes an already-armed marker without ever attempting a revoke rename',
      () async {
        final armedPath = '${tempDir.path}${io.Platform.pathSeparator}armed';
        final acceptedPath =
            '${tempDir.path}${io.Platform.pathSeparator}accepted';
        final revokedPath =
            '${tempDir.path}${io.Platform.pathSeparator}revoked';
        io.File(armedPath).createSync();
        io.File(acceptedPath).createSync();

        final (outcome, _) = await pollForRevokeOrArm(
          armedMarkerPath: armedPath,
          acceptedMarkerPath: acceptedPath,
          revokedMarkerPath: revokedPath,
          deadline: DateTime.now().add(const Duration(milliseconds: 30)),
          pollInterval: const Duration(milliseconds: 5),
          now: DateTime.now,
        );

        expect(outcome, RevokeOrArmOutcome.armed);
        // The accepted marker is untouched: the armed check short-circuits
        // before any revoke rename is even attempted.
        expect(io.File(acceptedPath).existsSync(), isTrue);
        expect(io.File(revokedPath).existsSync(), isFalse);
      },
    );

    test('wins a clean revoke when the accepted marker still exists and the '
        'armed marker never appears', () async {
      final armedPath = '${tempDir.path}${io.Platform.pathSeparator}armed';
      final acceptedPath =
          '${tempDir.path}${io.Platform.pathSeparator}accepted';
      final revokedPath = '${tempDir.path}${io.Platform.pathSeparator}revoked';
      io.File(acceptedPath).createSync();

      final (outcome, _) = await pollForRevokeOrArm(
        armedMarkerPath: armedPath,
        acceptedMarkerPath: acceptedPath,
        revokedMarkerPath: revokedPath,
        deadline: DateTime.now().add(const Duration(milliseconds: 30)),
        pollInterval: const Duration(milliseconds: 5),
        now: DateTime.now,
      );

      expect(outcome, RevokeOrArmOutcome.revoked);
      expect(io.File(revokedPath).existsSync(), isTrue);
    });

    test(
      'resolves as armed, not merely as a lost revoke, when the accepted '
      'marker is already gone because the worker\'s own rename won it first',
      () async {
        final armedPath = '${tempDir.path}${io.Platform.pathSeparator}armed';
        final acceptedPath =
            '${tempDir.path}${io.Platform.pathSeparator}accepted';
        final revokedPath =
            '${tempDir.path}${io.Platform.pathSeparator}revoked';
        // No accepted marker at all: the only rename it could have lost to
        // is the worker's own arm rename.

        final (outcome, _) = await pollForRevokeOrArm(
          armedMarkerPath: armedPath,
          acceptedMarkerPath: acceptedPath,
          revokedMarkerPath: revokedPath,
          deadline: DateTime.now().add(const Duration(milliseconds: 30)),
          pollInterval: const Duration(milliseconds: 5),
          now: DateTime.now,
        );

        expect(outcome, RevokeOrArmOutcome.armed);
        expect(io.File(revokedPath).existsSync(), isFalse);
      },
    );

    // Round 8 finding 1's central fix: an unexpected revoke-rename failure
    // (a sharing violation being the concrete case reported) must not be
    // reported as a lost race on its first occurrence; the worker could
    // still win moments later. This proves the retry actually happens, and
    // that a claim arriving only after the failure clears still resolves
    // correctly, mirroring pollForClaim's own equivalent test.
    test(
      'retries an unexpected revoke-rename failure instead of giving up on '
      'the first attempt, and still resolves once the failure clears',
      () async {
        final armedPath = '${tempDir.path}${io.Platform.pathSeparator}armed';
        final acceptedPath =
            '${tempDir.path}${io.Platform.pathSeparator}accepted';
        final revokedPath =
            '${tempDir.path}${io.Platform.pathSeparator}revoked';
        io.File(acceptedPath).createSync();
        final lock = io.File(acceptedPath).openSync(mode: io.FileMode.write);

        final future = pollForRevokeOrArm(
          armedMarkerPath: armedPath,
          acceptedMarkerPath: acceptedPath,
          revokedMarkerPath: revokedPath,
          deadline: DateTime.now().add(const Duration(seconds: 2)),
          pollInterval: const Duration(milliseconds: 20),
          now: DateTime.now,
        );

        // Held just long enough to provoke at least one failed attempt
        // before releasing it, well inside the deadline above.
        await Future<void>.delayed(const Duration(milliseconds: 60));
        lock.closeSync();

        final (outcome, _) = await future;
        expect(outcome, RevokeOrArmOutcome.revoked);
        expect(io.File(revokedPath).existsSync(), isTrue);
      },
      skip: io.Platform.isWindows
          ? false
          : 'provokes a real Windows sharing violation',
    );

    // The mirror of the retry test above: the worker's own arm rename wins
    // while the CLI's revoke attempts are still failing unexpectedly. Every
    // iteration checks the armed marker first, so this must notice that win
    // on the very next check after the lock clears, rather than attempting,
    // and losing, one more revoke rename first.
    test(
      'notices the worker winning mid-retry, checking the armed marker '
      'again before attempting another revoke rename',
      () async {
        final armedPath = '${tempDir.path}${io.Platform.pathSeparator}armed';
        final acceptedPath =
            '${tempDir.path}${io.Platform.pathSeparator}accepted';
        final revokedPath =
            '${tempDir.path}${io.Platform.pathSeparator}revoked';
        io.File(acceptedPath).createSync();
        final lock = io.File(acceptedPath).openSync(mode: io.FileMode.write);

        final future = pollForRevokeOrArm(
          armedMarkerPath: armedPath,
          acceptedMarkerPath: acceptedPath,
          revokedMarkerPath: revokedPath,
          deadline: DateTime.now().add(const Duration(seconds: 2)),
          pollInterval: const Duration(milliseconds: 20),
          now: DateTime.now,
        );

        await Future<void>.delayed(const Duration(milliseconds: 60));
        // Releases the lock and immediately performs the worker's own
        // winning rename synchronously, with no await between the two: on
        // a single isolate this runs to completion before any pending
        // timer (including pollForRevokeOrArm's own next retry, scheduled
        // through Future.delayed) gets a chance to fire, so this
        // deterministically wins the rename rather than racing it. The
        // rename itself must happen after the lock is released, not
        // before: while it is held, a real sharing violation blocks any
        // rename of the file, including this one, not only a competing
        // one.
        lock.closeSync();
        io.File(acceptedPath).renameSync(armedPath);

        final (outcome, _) = await future;
        expect(outcome, RevokeOrArmOutcome.armed);
        expect(io.File(revokedPath).existsSync(), isFalse);
      },
      skip: io.Platform.isWindows
          ? false
          : 'provokes a real Windows sharing violation',
    );

    // Round 8 finding 1: when the failure never clears before the deadline,
    // neither side is known to have won; this must resolve as unknown
    // rather than folding it into an ordinary revoked claim.
    test(
      'resolves as unknown once its own deadline passes while the revoke '
      'rename keeps failing unexpectedly the whole time',
      () async {
        final armedPath = '${tempDir.path}${io.Platform.pathSeparator}armed';
        final acceptedPath =
            '${tempDir.path}${io.Platform.pathSeparator}accepted';
        final revokedPath =
            '${tempDir.path}${io.Platform.pathSeparator}revoked';
        io.File(acceptedPath).createSync();
        final lock = io.File(acceptedPath).openSync(mode: io.FileMode.write);

        try {
          final (outcome, lastFailure) = await pollForRevokeOrArm(
            armedMarkerPath: armedPath,
            acceptedMarkerPath: acceptedPath,
            revokedMarkerPath: revokedPath,
            deadline: DateTime.now().add(const Duration(milliseconds: 100)),
            pollInterval: const Duration(milliseconds: 20),
            now: DateTime.now,
          );

          expect(outcome, RevokeOrArmOutcome.unknown);
          expect(io.File(revokedPath).existsSync(), isFalse);
          expect(io.File(armedPath).existsSync(), isFalse);
          // Finding 4 (round 9): the last unexpected FileSystemException is
          // carried alongside the unknown outcome instead of being
          // discarded once the deadline passes.
          expect(lastFailure, isA<io.FileSystemException>());
        } finally {
          lock.closeSync();
        }
      },
      skip: io.Platform.isWindows
          ? false
          : 'provokes a real Windows sharing violation',
    );
  });

  // Round 7 finding 1: a dead worker's marker still produced success. The
  // worker created its ready marker and then crashed (or was killed)
  // before ever reaching the accepted marker; the CLI still renamed ready
  // to accepted and, under the old single-phase protocol, reported
  // scheduled even though nobody was left to ever delete anything. This
  // composes the exact sequence IoCliProcessLauncher.startCleanupWorker
  // itself performs, directly against real files standing in for a real
  // private directory with no worker process at all, to prove the outcome
  // is now a revoked claim, deterministically, never a false success.
  group('the two-phase claim protocol composed end to end', () {
    late io.Directory tempDir;

    setUp(() {
      tempDir = io.Directory.systemTemp.createTempSync('two_phase_test_');
    });

    tearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    test('a worker that creates its ready marker and then goes silent '
        'forever, crashed or killed before ever reaching the accepted '
        'marker, is never reported as scheduled: winning the Phase 1 claim '
        'alone is not enough, and the Phase 2 ack deadline revokes it '
        'instead', () async {
      final readyPath = '${tempDir.path}${io.Platform.pathSeparator}ready';
      final acceptedPath =
          '${tempDir.path}${io.Platform.pathSeparator}accepted';
      final armedPath = '${tempDir.path}${io.Platform.pathSeparator}armed';
      final revokedPath =
          '${tempDir.path}${io.Platform.pathSeparator}$cleanupWorkerRevokedMarkerFileName';
      io.File(readyPath).createSync();

      final claimed = await pollForClaim(
        readyMarkerPath: readyPath,
        acceptedMarkerPath: acceptedPath,
        deadline: DateTime.now().add(const Duration(milliseconds: 30)),
        pollInterval: const Duration(milliseconds: 5),
        now: DateTime.now,
      );
      expect(
        claimed,
        isTrue,
        reason: 'Phase 1 succeeds: the dead worker did create its marker',
      );

      // The worker is dead: nothing here ever creates armedPath.
      final armed = await pollForArm(
        armedMarkerPath: armedPath,
        deadline: DateTime.now().add(const Duration(milliseconds: 30)),
        pollInterval: const Duration(milliseconds: 5),
        now: DateTime.now,
      );
      expect(armed, isFalse);

      // Round 8: IoCliProcessLauncher no longer decides the Phase 2 race
      // with a single bare tryRevokeAcceptedMarker attempt once pollForArm
      // gives up; it resolves it through pollForRevokeOrArm instead, which
      // this composes here the same way startCleanupWorker itself does.
      final (outcome, _) = await pollForRevokeOrArm(
        armedMarkerPath: armedPath,
        acceptedMarkerPath: acceptedPath,
        revokedMarkerPath: revokedPath,
        deadline: DateTime.now().add(const Duration(milliseconds: 30)),
        pollInterval: const Duration(milliseconds: 5),
        now: DateTime.now,
      );
      expect(
        outcome,
        RevokeOrArmOutcome.revoked,
        reason:
            'nothing was left to contest the revoke, so it wins, exactly '
            'the signal IoCliProcessLauncher.startCleanupWorker uses to '
            'report failure instead of a false success',
      );
      expect(io.File(revokedPath).existsSync(), isTrue);
      expect(io.File(armedPath).existsSync(), isFalse);
    });
  });

  group('pollForClaim', () {
    late io.Directory tempDir;

    setUp(() {
      tempDir = io.Directory.systemTemp.createTempSync('poll_claim_test_');
    });

    tearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    // This is the exact interleaving Codex's round 6 finding 1 described:
    // the CLI is suspended right up to (here, past) its own deadline, and
    // only resumes afterwards. A deadline check alone would give up without
    // ever trying again; pollForClaim instead always attempts the claim at
    // least once, so a marker the worker created in time is still won.
    test('wins on its very first attempt even when its own clock already '
        'reads past the deadline, so a CLI that resumes suspended past its '
        'deadline still claims a marker the worker created in time', () async {
      final readyPath = '${tempDir.path}${io.Platform.pathSeparator}ready';
      final acceptedPath =
          '${tempDir.path}${io.Platform.pathSeparator}accepted';
      io.File(readyPath).createSync();
      final pastDeadline = DateTime.now().subtract(const Duration(seconds: 1));

      final claimed = await pollForClaim(
        readyMarkerPath: readyPath,
        acceptedMarkerPath: acceptedPath,
        deadline: pastDeadline,
        pollInterval: const Duration(milliseconds: 5),
        now: DateTime.now,
      );

      expect(claimed, isTrue);
      expect(io.File(acceptedPath).existsSync(), isTrue);
    });

    test('gives up once the deadline passes when the ready marker never '
        'appears', () async {
      final readyPath = '${tempDir.path}${io.Platform.pathSeparator}ready';
      final acceptedPath =
          '${tempDir.path}${io.Platform.pathSeparator}accepted';

      final claimed = await pollForClaim(
        readyMarkerPath: readyPath,
        acceptedMarkerPath: acceptedPath,
        deadline: DateTime.now().add(const Duration(milliseconds: 30)),
        pollInterval: const Duration(milliseconds: 5),
        now: DateTime.now,
      );

      expect(claimed, isFalse);
      expect(io.File(acceptedPath).existsSync(), isFalse);
    });

    test('gives up when the worker wins the claim first, even though the '
        'ready marker briefly existed', () async {
      final readyPath = '${tempDir.path}${io.Platform.pathSeparator}ready';
      final acceptedPath =
          '${tempDir.path}${io.Platform.pathSeparator}accepted';
      final abandonedPath =
          '${tempDir.path}${io.Platform.pathSeparator}abandoned';
      io.File(readyPath).createSync();
      io.File(readyPath).renameSync(abandonedPath);

      final claimed = await pollForClaim(
        readyMarkerPath: readyPath,
        acceptedMarkerPath: acceptedPath,
        deadline: DateTime.now().add(const Duration(milliseconds: 30)),
        pollInterval: const Duration(milliseconds: 5),
        now: DateTime.now,
      );

      expect(claimed, isFalse);
      expect(io.File(acceptedPath).existsSync(), isFalse);
    });

    // Round 7 finding 2, applied symmetrically to the CLI's own side of the
    // same claim: a transient unexpected rename failure (a sharing
    // violation being the concrete case a freshly created file can briefly
    // see on Windows, provoked here the same way as elsewhere) must not
    // abandon polling on its first occurrence. pollForClaim keeps retrying
    // through it, on the same poll interval as any other failed attempt,
    // and still wins the claim once whatever caused it clears, well before
    // its own deadline.
    test(
      'retries through a transient unexpected rename failure instead of '
      'abandoning the claim on its first occurrence, and still wins once '
      'the failure clears',
      () async {
        final readyPath = '${tempDir.path}${io.Platform.pathSeparator}ready';
        final acceptedPath =
            '${tempDir.path}${io.Platform.pathSeparator}accepted';
        io.File(readyPath).createSync();
        final lock = io.File(readyPath).openSync(mode: io.FileMode.write);

        final future = pollForClaim(
          readyMarkerPath: readyPath,
          acceptedMarkerPath: acceptedPath,
          deadline: DateTime.now().add(const Duration(seconds: 2)),
          pollInterval: const Duration(milliseconds: 20),
          now: DateTime.now,
        );

        // Held just long enough to provoke at least one failed attempt
        // before releasing it, well inside the deadline above.
        await Future<void>.delayed(const Duration(milliseconds: 60));
        lock.closeSync();

        final claimed = await future;
        expect(claimed, isTrue);
        expect(io.File(acceptedPath).existsSync(), isTrue);
      },
      skip: io.Platform.isWindows
          ? false
          : 'provokes a real Windows sharing violation',
    );

    // The mirror of the test above: once the deadline has genuinely
    // passed with the unexpected failure still unresolved, pollForClaim
    // lets it propagate rather than reporting an ordinary "gave up"
    // false, since the caller still deserves the real, specific reason.
    test(
      'propagates the unexpected rename failure once the deadline has '
      'already passed while it is still unresolved, rather than reporting '
      'an ordinary lost claim',
      () async {
        final readyPath = '${tempDir.path}${io.Platform.pathSeparator}ready';
        final acceptedPath =
            '${tempDir.path}${io.Platform.pathSeparator}accepted';
        io.File(readyPath).createSync();
        final lock = io.File(readyPath).openSync(mode: io.FileMode.write);

        try {
          await expectLater(
            pollForClaim(
              readyMarkerPath: readyPath,
              acceptedMarkerPath: acceptedPath,
              deadline: DateTime.now().subtract(
                const Duration(milliseconds: 1),
              ),
              pollInterval: const Duration(milliseconds: 5),
              now: DateTime.now,
            ),
            throwsA(isA<io.FileSystemException>()),
          );
        } finally {
          lock.closeSync();
        }
      },
      skip: io.Platform.isWindows
          ? false
          : 'provokes a real Windows sharing violation',
    );
  });

  test('cleanupWorkerReadyMarkerFileName is the fixed literal the CLI and the '
      'worker both build the ready marker\'s path from', () {
    expect(cleanupWorkerReadyMarkerFileName, 'ready');
  });

  group('cleanupWorkerEncodedBootstrapScript', () {
    test('is the fixed bootstrap script Base64-encoded as UTF-16LE', () {
      final decoded = String.fromCharCodes(
        _decodeUtf16Le(base64.decode(cleanupWorkerEncodedBootstrapScript)),
      );
      expect(decoded, cleanupWorkerBootstrapScript);
    });
  });

  group('cleanupWorkerCmdCommandLine', () {
    test('stays well under cmd.exe\'s roughly 8191-character limit', () {
      final commandLine = cleanupWorkerCmdCommandLine(
        r'C:\Windows\System32\cmd.exe',
        r'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe',
      );
      expect(commandLine.length, lessThan(8191));
    });

    test('carries the encoded bootstrap script and the PowerShell path', () {
      final commandLine = cleanupWorkerCmdCommandLine(
        r'C:\Windows\System32\cmd.exe',
        r'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe',
      );
      expect(commandLine, contains(cleanupWorkerEncodedBootstrapScript));
      expect(
        commandLine,
        contains(r'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'),
      );
      expect(commandLine, contains('-EncodedCommand'));
      // No -File and no script path at all: there is no script file to name.
      expect(commandLine, isNot(contains('-File')));
    });
  });

  group('powershellExecutablePath', () {
    test('resolves the fixed path under SystemRoot', () {
      expect(
        powershellExecutablePath({'SystemRoot': r'C:\Windows'}),
        r'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe',
      );
    });

    test('throws CliCleanupWorkerStartFailure when SystemRoot is absent', () {
      expect(
        () => powershellExecutablePath({}),
        throwsA(isA<CliCleanupWorkerStartFailure>()),
      );
    });

    test('throws CliCleanupWorkerStartFailure when SystemRoot is empty', () {
      expect(
        () => powershellExecutablePath({'SystemRoot': ''}),
        throwsA(isA<CliCleanupWorkerStartFailure>()),
      );
    });

    // The resolved path is the only run-specific value that ever appears on
    // the cmd.exe command line IoCliProcessLauncher builds: a SystemRoot an
    // attacker controls (or one simply misconfigured) must not be able to
    // inject an extra command or escape the intended argument.
    for (final metacharacter in const [
      '&',
      '|',
      '<',
      '>',
      '^',
      '%',
      '!',
      '"',
    ]) {
      test('throws CliCleanupWorkerStartFailure when SystemRoot contains '
          '$metacharacter', () {
        expect(
          () => powershellExecutablePath({
            'SystemRoot': 'C:\\Windows${metacharacter}evil',
          }),
          throwsA(isA<CliCleanupWorkerStartFailure>()),
        );
      });
    }
  });

  group('cmdExecutablePath', () {
    test('resolves the fixed path under SystemRoot', () {
      expect(
        cmdExecutablePath({'SystemRoot': r'C:\Windows'}),
        r'C:\Windows\System32\cmd.exe',
      );
    });

    test('throws CliCleanupWorkerStartFailure when SystemRoot is absent', () {
      expect(
        () => cmdExecutablePath({}),
        throwsA(isA<CliCleanupWorkerStartFailure>()),
      );
    });

    test('throws CliCleanupWorkerStartFailure when SystemRoot is empty', () {
      expect(
        () => cmdExecutablePath({'SystemRoot': ''}),
        throwsA(isA<CliCleanupWorkerStartFailure>()),
      );
    });
  });

  group('IoCliProcessLauncher.startCleanupWorker', () {
    test(
      'deletes the given path once the parent process it was told to '
      'watch exits, and not before',
      () async {
        final tempDir = io.Directory.systemTemp.createTempSync(
          'cleanup_worker_test_',
        );
        addTearDown(() {
          if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
        });
        final targetPath =
            '${tempDir.path}${io.Platform.pathSeparator}victim.txt';
        io.File(targetPath).writeAsStringSync('gone soon');

        final parent = await io.Process.start('powershell', [
          '-NoProfile',
          '-NonInteractive',
          '-Command',
          'Start-Sleep -Seconds 60',
        ]);

        try {
          const launcher = IoCliProcessLauncher();
          await launcher.startCleanupWorker({
            'parentPid': parent.pid,
            'paths': [targetPath],
          });

          // The worker has signalled ready, but the parent it is waiting on
          // is still alive: nothing has been deleted yet.
          await Future<void>.delayed(const Duration(seconds: 1));
          expect(io.File(targetPath).existsSync(), isTrue);

          parent.kill();
          await parent.exitCode;

          final deadline = DateTime.now().add(const Duration(seconds: 20));
          while (io.File(targetPath).existsSync() &&
              DateTime.now().isBefore(deadline)) {
            await Future<void>.delayed(const Duration(milliseconds: 200));
          }
          expect(io.File(targetPath).existsSync(), isFalse);
        } finally {
          try {
            parent.kill();
          } on Object {
            // Already gone; nothing left to clean up.
          }
        }
      },
      skip: io.Platform.isWindows
          ? false
          : 'launches a real Windows PowerShell cleanup worker',
      timeout: const Timeout(Duration(seconds: 40)),
    );

    test(
      'the worker survives even when the process that launched it exits '
      'immediately afterwards, the way a real CLI run does',
      () async {
        final tempDir = io.Directory.systemTemp.createTempSync(
          'cleanup_worker_survival_test_',
        );
        addTearDown(() {
          if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
        });
        // Tricky characters the payload environment variable must carry
        // through untouched: no shell (cmd.exe's or PowerShell's) ever
        // parses this path, only ConvertFrom-Json does.
        const trickyName = "victim that's (weird) 100% & loud!.txt";
        final targetPath =
            '${tempDir.path}${io.Platform.pathSeparator}$trickyName';
        io.File(targetPath).writeAsStringSync('gone soon');

        // `dart run` resolves the package config by walking up from the
        // script's own location, not from the working directory it is
        // launched with: the helper has to live inside this package, not
        // in a system temp directory outside it.
        final helperScript =
            io.File(
              'test/plugins/installation/.cleanup_worker_survival_helper.dart',
            )..writeAsStringSync('''
import 'package:modular_cli_sdk/modular_cli_sdk.dart';

Future<void> main(List<String> args) async {
  const launcher = IoCliProcessLauncher();
  await launcher.startCleanupWorker({
    'parentPid': launcher.currentPid,
    'paths': [args[0]],
  });
}
''');
        addTearDown(() {
          if (helperScript.existsSync()) helperScript.deleteSync();
        });

        final result = await io.Process.run(
          io.Platform.resolvedExecutable,
          ['run', helperScript.path, targetPath],
          workingDirectory: io.Directory.current.path,
        );
        expect(
          result.exitCode,
          0,
          reason:
              'the helper process must confirm the worker is ready before '
              'it exits: ${result.stdout}\n${result.stderr}',
        );

        // The helper process (the "CLI") has already fully exited by now:
        // this is exactly the scenario ProcessStartMode.normal cannot
        // survive, because Windows kills a normal child's whole job when
        // its launcher exits.
        final deadline = DateTime.now().add(const Duration(seconds: 20));
        while (io.File(targetPath).existsSync() &&
            DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }
        expect(io.File(targetPath).existsSync(), isFalse);
      },
      skip: io.Platform.isWindows
          ? false
          : 'launches a real Windows PowerShell cleanup worker',
      timeout: const Timeout(Duration(seconds: 40)),
    );

    test(
      'a TEMP directory containing cmd.exe metacharacters and spaces does '
      'not break the launch or the eventual deletion',
      () async {
        final realTemp = io.Directory.systemTemp;
        final trickyTempDir = io.Directory(
          '${realTemp.path}${io.Platform.pathSeparator}'
          'cli_test_tricky_&%!^() dir',
        )..createSync();
        addTearDown(() {
          if (trickyTempDir.existsSync()) {
            trickyTempDir.deleteSync(recursive: true);
          }
        });

        final targetPath =
            '${trickyTempDir.path}${io.Platform.pathSeparator}victim.txt';
        io.File(targetPath).writeAsStringSync('gone soon');

        final helperScript =
            io.File(
              'test/plugins/installation/.cleanup_worker_tricky_temp_helper.dart',
            )..writeAsStringSync('''
import 'package:modular_cli_sdk/modular_cli_sdk.dart';

Future<void> main(List<String> args) async {
  const launcher = IoCliProcessLauncher();
  await launcher.startCleanupWorker({
    'parentPid': launcher.currentPid,
    'paths': [args[0]],
  });
}
''');
        addTearDown(() {
          if (helperScript.existsSync()) helperScript.deleteSync();
        });

        final result = await io.Process.run(
          io.Platform.resolvedExecutable,
          ['run', helperScript.path, targetPath],
          workingDirectory: io.Directory.current.path,
          environment: {
            ...io.Platform.environment,
            'TEMP': trickyTempDir.path,
            'TMP': trickyTempDir.path,
          },
        );
        expect(
          result.exitCode,
          0,
          reason:
              'the helper process must confirm the worker is ready before '
              'it exits: ${result.stdout}\n${result.stderr}',
        );

        final deadline = DateTime.now().add(const Duration(seconds: 20));
        while (io.File(targetPath).existsSync() &&
            DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }
        expect(io.File(targetPath).existsSync(), isFalse);
      },
      skip: io.Platform.isWindows
          ? false
          : 'launches a real Windows PowerShell cleanup worker',
      timeout: const Timeout(Duration(seconds: 40)),
    );

    test(
      'deletes a target whose path contains non-ASCII characters',
      () async {
        final tempDir = io.Directory.systemTemp.createTempSync(
          'cleanup_worker_unicode_test_',
        );
        addTearDown(() {
          if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
        });
        final targetPath =
            '${tempDir.path}${io.Platform.pathSeparator}José.txt';
        io.File(targetPath).writeAsStringSync('gone soon');

        final helperScript =
            io.File(
              'test/plugins/installation/.cleanup_worker_unicode_helper.dart',
            )..writeAsStringSync('''
import 'package:modular_cli_sdk/modular_cli_sdk.dart';

Future<void> main(List<String> args) async {
  const launcher = IoCliProcessLauncher();
  await launcher.startCleanupWorker({
    'parentPid': launcher.currentPid,
    'paths': [args[0]],
  });
}
''');
        addTearDown(() {
          if (helperScript.existsSync()) helperScript.deleteSync();
        });

        final result = await io.Process.run(
          io.Platform.resolvedExecutable,
          ['run', helperScript.path, targetPath],
          workingDirectory: io.Directory.current.path,
        );
        expect(
          result.exitCode,
          0,
          reason:
              'the helper process must confirm the worker is ready before '
              'it exits: ${result.stdout}\n${result.stderr}',
        );

        final deadline = DateTime.now().add(const Duration(seconds: 20));
        while (io.File(targetPath).existsSync() &&
            DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }
        expect(io.File(targetPath).existsSync(), isFalse);
      },
      skip: io.Platform.isWindows
          ? false
          : 'launches a real Windows PowerShell cleanup worker',
      timeout: const Timeout(Duration(seconds: 40)),
    );

    // Round 6 finding 1: once the CLI's claim rename succeeds, cleaning up
    // the private directory immediately, the way startCleanupWorker used
    // to, races the worker's own, still-pending, first look at the accepted
    // marker; a private directory deleted out from under that look is
    // indistinguishable, to the worker, from the CLI never having claimed
    // it at all, and the worker would wrongly conclude it lost and never
    // delete the real target. Ownership of the private directory therefore
    // moves to the worker itself on this path: it removes it only once it
    // has actually finished deleting the target paths it was given, never
    // before.
    test(
      'leaves no private directory behind once the worker has finished '
      'deleting the target paths it was given',
      () async {
        final tempDir = io.Directory.systemTemp.createTempSync(
          'cleanup_worker_artifact_test_',
        );
        addTearDown(() {
          if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
        });
        final targetPath =
            '${tempDir.path}${io.Platform.pathSeparator}victim.txt';
        io.File(targetPath).writeAsStringSync('gone soon');

        final before = _existingCleanupPrivateDirs();

        final parent = await io.Process.start('powershell', [
          '-NoProfile',
          '-NonInteractive',
          '-Command',
          'Start-Sleep -Seconds 60',
        ]);

        try {
          const launcher = IoCliProcessLauncher();
          await launcher.startCleanupWorker({
            'parentPid': parent.pid,
            'paths': [targetPath],
          });

          // The worker has claimed the run, but the parent it is waiting on
          // is still alive: neither the target nor the private directory
          // has been touched yet.
          await Future<void>.delayed(const Duration(seconds: 1));
          expect(io.File(targetPath).existsSync(), isTrue);

          parent.kill();
          await parent.exitCode;

          final deadline = DateTime.now().add(const Duration(seconds: 20));
          while (io.File(targetPath).existsSync() &&
              DateTime.now().isBefore(deadline)) {
            await Future<void>.delayed(const Duration(milliseconds: 200));
          }
          expect(io.File(targetPath).existsSync(), isFalse);

          expect(
            _existingCleanupPrivateDirs(),
            before,
            reason:
                'the worker must remove its own private directory once it '
                'has finished deleting the target paths it was given',
          );
        } finally {
          try {
            parent.kill();
          } on Object {
            // Already gone; nothing left to clean up.
          }
        }
      },
      skip: io.Platform.isWindows
          ? false
          : 'launches a real Windows PowerShell cleanup worker',
      timeout: const Timeout(Duration(seconds: 40)),
    );

    // Round 5 finding 1, corrected by round 6 finding 2.
    test(
      'a parent process the worker cannot get a handle on (as opposed to '
      'one that does not exist) stops the worker before it creates the '
      'marker, so startCleanupWorker reports cleanup-start-failed rather '
      'than silently treating access-denied as "parent already exited"',
      () async {
        // pid 4 is the Windows kernel's own "System" process: a real,
        // always-running pid, so GetProcessById(4) itself succeeds and this
        // is not the "no such process" ArgumentException case finding 1
        // also has to tell apart. get_Handle() (round 6 finding 2's fix,
        // not the bare .Handle property, which can return $null instead of
        // throwing here) is expected to return null or a zero handle. If
        // this environment's token can retain a non-zero handle on it after
        // all, the premise this test needs does not hold here, and it skips
        // with that reason rather than asserting a behaviour it cannot
        // actually provoke.
        final probe = await io.Process.run('powershell', [
          '-NoProfile',
          '-NonInteractive',
          '-Command',
          r'try { '
              r'$h = ([System.Diagnostics.Process]::GetProcessById(4)).get_Handle(); '
              r'if ($null -eq $h -or $h -eq [IntPtr]::Zero) { "handle-denied" } '
              r'else { "handle-ok" } '
              r'} catch { "handle-denied" }',
        ]);
        if (probe.stdout.toString().trim() != 'handle-denied') {
          markTestSkipped(
            'this environment\'s token can retain a non-zero '
            'Process.get_Handle() on pid 4 (the System process), so it '
            'cannot reproduce the access-denied case this test needs: '
            '${probe.stdout}',
          );
          return;
        }

        final before = _existingCleanupPrivateDirs();
        const launcher = IoCliProcessLauncher();

        await expectLater(
          launcher.startCleanupWorker({'parentPid': 4, 'paths': <String>[]}),
          throwsA(isA<CliCleanupWorkerStartFailure>()),
        );

        expect(
          _existingCleanupPrivateDirs(),
          before,
          reason:
              'a worker stopped by an access-denied handle failure must '
              'leave no private directory behind either',
        );
      },
      skip: io.Platform.isWindows
          ? false
          : 'launches a real Windows PowerShell cleanup worker',
      timeout: const Timeout(Duration(seconds: 40)),
    );

    // Round 5 finding 2(b).
    test(
      'a worker that starts too close to the CLI giving up refuses to '
      'create the marker, or recreate the private directory, and deletes '
      'nothing',
      () async {
        final tempDir = io.Directory.systemTemp.createTempSync(
          'cleanup_worker_deadline_test_',
        );
        addTearDown(() {
          if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
        });
        final targetPath =
            '${tempDir.path}${io.Platform.pathSeparator}victim.txt';
        io.File(targetPath).writeAsStringSync('gone soon');

        final before = _existingCleanupPrivateDirs();

        // A genuine, already-exited short-lived process, not this test
        // runner's own pid (round 6 finding 1): the assertion below that
        // the target still exists is only meaningful proof that deletion
        // was never armed if the watched parent has definitely already
        // exited by the time it runs, rather than merely being this still
        // very much alive test process.
        final shortLivedParent = await io.Process.start('cmd', [
          '/c',
          'exit',
          '0',
        ]);
        final shortLivedParentPid = shortLivedParent.pid;
        await shortLivedParent.exitCode;

        // A safety margin almost as large as the startup timeout itself
        // leaves the worker only a few milliseconds, from launch, to
        // create its marker: nowhere near enough for a real powershell.exe
        // process to even finish starting, let alone parse its payload and
        // reach the marker-creation step. The CLI's own timeout is left
        // long enough (2s) for that real process to actually run to
        // completion (refusing to create the marker, and so deleting
        // nothing) before this test moves on to asserting that.
        final launcher = IoCliProcessLauncher(
          startupTimeout: const Duration(seconds: 2),
          markerDeadlineSafetyMargin: const Duration(milliseconds: 1990),
        );

        await expectLater(
          launcher.startCleanupWorker({
            'parentPid': shortLivedParentPid,
            'paths': [targetPath],
          }),
          throwsA(isA<CliCleanupWorkerStartFailure>()),
        );

        // Gives the real, still-running worker time to reach its own
        // deadline check and exit, so a bug that let it through would
        // already have shown itself by the time the assertions below run.
        await Future<void>.delayed(const Duration(seconds: 3));

        expect(
          io.File(targetPath).existsSync(),
          isTrue,
          reason:
              'a worker that started past its own deadline must delete '
              'nothing',
        );
        expect(
          _existingCleanupPrivateDirs(),
          before,
          reason:
              'a worker that started past its own deadline must not '
              'recreate the private directory the CLI already gave up on',
        );
      },
      skip: io.Platform.isWindows
          ? false
          : 'launches a real Windows PowerShell cleanup worker',
      timeout: const Timeout(Duration(seconds: 40)),
    );

    // Round 5 finding 4 introduced a warning startCleanupWorker returned on
    // success if its own attempt to remove the private directory failed.
    // Round 6 finding 1 removed that attempt entirely: cleaning up the
    // private directory immediately after a successful claim is exactly
    // the race that let the CLI's report and the worker's own later
    // decision disagree, so that responsibility now belongs to the worker
    // alone on the success path (see "leaves no private directory behind
    // once the worker has finished..." above), and startCleanupWorker
    // itself never attempts, or reports on, that removal anymore. Only the
    // failure path below, where deletePrivateDirectoryLauncher's seam is
    // still the only portable way to provoke a real cleanup failure
    // deterministically, remains.
    test(
      'a launch failure names a cleanup-directory failure in its own '
      'message when both fail',
      () async {
        final launcher = _FailingCleanupDirectoryLauncher(
          Exception('directory busy'),
          startupTimeout: const Duration(milliseconds: 500),
        );

        await expectLater(
          launcher.startCleanupWorker({
            // Not an integer: the worker's $ErrorActionPreference = 'Stop'
            // makes [int]$data.parentPid throw before it ever creates its
            // ready-marker file, so this never confirms ready and
            // startCleanupWorker times out waiting for it, the primary
            // failure this test's cleanup-directory failure must be
            // attached to rather than replace.
            'parentPid': 'not-a-pid',
            'paths': <String>[],
          }),
          throwsA(
            isA<CliCleanupWorkerStartFailure>()
                .having(
                  (e) => e.message,
                  'message',
                  contains('did not confirm it was ready'),
                )
                .having(
                  (e) => e.message,
                  'message',
                  contains('directory busy'),
                ),
          ),
        );
      },
      skip: io.Platform.isWindows
          ? false
          : 'launches a real Windows PowerShell cleanup worker',
      timeout: const Timeout(Duration(seconds: 40)),
    );

    test(
      'leaves no private directory behind when the worker never confirms '
      'ready',
      () async {
        final before = _existingCleanupPrivateDirs();

        const launcher = IoCliProcessLauncher();
        await expectLater(
          launcher.startCleanupWorker({
            // Not an integer: the worker's $ErrorActionPreference = 'Stop'
            // makes [int]$data.parentPid throw before it ever creates its
            // ready-marker file, so this never confirms ready and
            // startCleanupWorker times out waiting for it.
            'parentPid': 'not-a-pid',
            'paths': <String>[],
          }),
          throwsA(isA<CliCleanupWorkerStartFailure>()),
        );

        expect(
          _existingCleanupPrivateDirs(),
          before,
          reason:
              'the private directory created for the ready marker must be '
              'removed even when the worker never confirms ready',
        );
      },
      skip: io.Platform.isWindows
          ? false
          : 'launches a real Windows PowerShell cleanup worker',
      timeout: const Timeout(Duration(seconds: 40)),
    );

    // Round 7 finding 3: the worker used to give up on its own parent
    // after a fixed 5 minute wait and exit without ever deleting anything,
    // leaving both the target paths and the worker-owned private directory
    // behind if the parent (a suspended CLI, or simply a long-lived host)
    // was still alive past that mark. The fix removed the cap entirely: an
    // armed worker now waits on the parent handle with no timeout at all.
    // See "the removed unbounded-wait cap actually mattered" below for
    // Round 8 finding 4's replacement of this scenario's original,
    // non-diagnostic test.

    // Round 8 finding 1: a single failed revoke attempt used to be reported
    // as an ordinary CliCleanupWorkerStartFailure straight away, removing
    // the private directory in the process, even though the worker could
    // still win the arm race the moment the failure cleared. This provokes
    // that exact interleaving through the real launcher: a real sharing
    // violation on the accepted marker, held across both
    // IoCliProcessLauncher's own ack and revoke deadlines, forces a genuine
    // CliCleanupOutcomeUnknown; then, once the lock clears, the worker
    // (never having given up on its own) goes on to win the arm race and
    // actually delete the target, proving the private directory was
    // correctly left in place rather than removed out from under it.
    test(
      'reports CliCleanupOutcomeUnknown, and leaves the private directory '
      'in place, when a real sharing violation on the accepted marker '
      'outlasts both the ack and revoke deadlines, and the worker goes on '
      'to arm and delete the target once the violation clears',
      () async {
        final tempDir = io.Directory.systemTemp.createTempSync(
          'cleanup_worker_outcome_unknown_test_',
        );
        addTearDown(() {
          if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
        });
        final targetPath =
            '${tempDir.path}${io.Platform.pathSeparator}victim.txt';
        io.File(targetPath).writeAsStringSync('gone soon');

        final before = _existingCleanupPrivateDirs();

        final parent = await io.Process.start('powershell', [
          '-NoProfile',
          '-NonInteractive',
          '-Command',
          'Start-Sleep -Seconds 60',
        ]);

        final launcher = _ArmBarrierLauncher(
          ackTimeout: const Duration(milliseconds: 300),
          revokeTimeout: const Duration(milliseconds: 300),
        );

        io.RandomAccessFile? lock;
        try {
          final resultFuture = launcher.startCleanupWorker({
            'parentPid': parent.pid,
            'paths': [targetPath],
          });

          // Phase A: finds the private directory the launcher just
          // created. This does not race the worker at all: the worker
          // creates the ready marker, and so the directory, well before
          // anyone can claim or arm anything, so a poll on
          // cleanupWorkerReadyPollInterval's own cadence is both cheap
          // (listSync() over the whole system temp directory is a
          // synchronous, blocking call, and polling it too tightly starves
          // the event loop the launcher's own futures need to make
          // progress on) and in no hurry.
          final findDeadline = DateTime.now().add(const Duration(seconds: 20));
          String? privateDirPath;
          while (DateTime.now().isBefore(findDeadline)) {
            final created = _existingCleanupPrivateDirs().difference(before);
            if (created.isNotEmpty) {
              privateDirPath = created.first;
              break;
            }
            await Future<void>.delayed(cleanupWorkerReadyPollInterval);
          }
          expect(
            privateDirPath,
            isNotNull,
            reason: 'the CLI must have started the worker well within 20s',
          );
          final acceptedPath =
              '$privateDirPath${io.Platform.pathSeparator}'
              '$cleanupWorkerAcceptedMarkerFileName';

          // Phase B: waits for the accepted marker the CLI's own Phase 1
          // claim creates. No longer a race against the worker's own arm
          // rename (Round 9 finding 2): _ArmBarrierLauncher's worker script
          // waits for _armBarrierReleaseMarkerFileName before ever
          // attempting that rename, so this poll only has to notice a
          // marker the worker has not yet been allowed to contest.
          final claimDeadline = DateTime.now().add(const Duration(seconds: 20));
          while (!io.File(acceptedPath).existsSync() &&
              DateTime.now().isBefore(claimDeadline)) {
            await Future<void>.delayed(const Duration(milliseconds: 1));
          }
          expect(
            io.File(acceptedPath).existsSync(),
            isTrue,
            reason: 'the CLI must have won Phase 1 well within 20s',
          );

          // Locks the accepted marker while the worker is still waiting on
          // the release marker below, so neither its own arm rename nor
          // the CLI's later revoke rename can complete until this is
          // released.
          lock = io.File(acceptedPath).openSync(mode: io.FileMode.write);

          // Only now does the worker's own arm rename become contestable:
          // it has been waiting on this marker since before the accepted
          // marker even existed.
          io.File(_armBarrierReleaseMarkerPath(privateDirPath!)).createSync();

          await expectLater(
            resultFuture,
            throwsA(isA<CliCleanupOutcomeUnknown>()),
          );

          expect(
            _existingCleanupPrivateDirs().difference(before),
            isNotEmpty,
            reason:
                'CliCleanupOutcomeUnknown must leave the private directory '
                'in place: the worker may still be alive and using it',
          );

          lock.closeSync();
          lock = null;

          // The worker was never told to give up: once the violation
          // clears, it wins its own arm rename and, once the parent exits,
          // actually deletes the target and removes its own directory.
          parent.kill();
          await parent.exitCode;

          final deleteDeadline = DateTime.now().add(
            const Duration(seconds: 20),
          );
          while ((io.File(targetPath).existsSync() ||
                  _existingCleanupPrivateDirs()
                      .difference(before)
                      .isNotEmpty) &&
              DateTime.now().isBefore(deleteDeadline)) {
            await Future<void>.delayed(const Duration(milliseconds: 200));
          }
          expect(io.File(targetPath).existsSync(), isFalse);
          expect(_existingCleanupPrivateDirs(), before);
        } finally {
          lock?.closeSync();
          try {
            parent.kill();
          } on Object {
            // Already gone; nothing left to clean up.
          }
        }
      },
      skip: io.Platform.isWindows
          ? false
          : 'provokes a real Windows sharing violation through the real '
                'launcher',
      timeout: const Timeout(Duration(seconds: 60)),
    );
  });

  // Round 8 finding 2: the worker's only two ways to stop are its own
  // successful rename (a legitimate win, or a legitimate "source not found"
  // loss) or observing that the accepted marker itself is gone; never a
  // deadline it gives up at while a claimable marker still exists. These
  // exercise both renames (abandon and arm) through the real, unmodified
  // script directly, holding a real sharing violation on the marker each
  // one targets well past where the removed cap, or any shorter interval,
  // would have made the old code give up, then releasing it and confirming
  // the worker still completes the transition rather than having exited
  // long before.
  group(
    'the cleanup worker never gives up while a claimable marker exists',
    () {
      late io.Directory tempDir;

      setUp(() {
        tempDir = io.Directory.systemTemp.createTempSync(
          'worker_no_give_up_test_',
        );
      });

      tearDown(() {
        if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
      });

      test(
        'the arm rename keeps retrying a real sharing violation on the '
        'accepted marker well past a short stand-in for the old cap, and '
        'still succeeds once it clears',
        () async {
          final readyPath = '${tempDir.path}${io.Platform.pathSeparator}ready';
          final acceptedPath =
              '${tempDir.path}${io.Platform.pathSeparator}accepted';
          final armedPath = '${tempDir.path}${io.Platform.pathSeparator}armed';
          final targetPath =
              '${tempDir.path}${io.Platform.pathSeparator}victim.txt';
          io.File(targetPath).writeAsStringSync('gone soon');
          const oldCapStandIn = Duration(seconds: 5);

          final parent = await io.Process.start('powershell', [
            '-NoProfile',
            '-NonInteractive',
            '-Command',
            'Start-Sleep -Seconds 60',
          ]);

          final nowUnixMs = DateTime.now().toUtc().millisecondsSinceEpoch;
          final worker = await _startWorkerProcess(
            {
              'parentPid': parent.pid,
              'paths': [targetPath],
              'markerDeadlineUnixMs': nowUnixMs + 30000,
              'claimDeadlineUnixMs': nowUnixMs + 30000,
            },
            readyPath,
            encodedScript: _armBarrierEncodedScript,
          );

          io.RandomAccessFile? lock;
          try {
            final readyDeadline = DateTime.now().add(
              const Duration(seconds: 20),
            );
            while (!io.File(readyPath).existsSync() &&
                DateTime.now().isBefore(readyDeadline)) {
              await Future<void>.delayed(const Duration(milliseconds: 5));
            }
            expect(io.File(readyPath).existsSync(), isTrue);

            // This test's own claim: the exact retrying claim
            // IoCliProcessLauncher.startCleanupWorker itself performs.
            expect(
              await _claimReadyMarkerForTest(readyPath, acceptedPath),
              isTrue,
            );
            lock = io.File(acceptedPath).openSync(mode: io.FileMode.write);

            // Round 9 finding 2: the worker (running _armBarrierEncodedScript,
            // not the real, unmodified script) has been waiting for this
            // release marker since before the accepted marker even existed,
            // so only releasing it now, with the lock above already
            // installed, makes the arm rename it is about to attempt
            // contestable at all: no race against its own 50ms poll cadence
            // to win.
            io.File(_armBarrierReleaseMarkerPath(tempDir.path)).createSync();

            await Future<void>.delayed(
              oldCapStandIn + const Duration(seconds: 2),
            );
            expect(
              await _isStillRunning(worker),
              isTrue,
              reason:
                  'a worker retrying an unexpected arm-rename failure with '
                  'no cap of its own must still be alive well past any short '
                  'interval that used to be enough to make it give up',
            );
            expect(io.File(armedPath).existsSync(), isFalse);

            lock.closeSync();
            lock = null;

            final armedDeadline = DateTime.now().add(
              const Duration(seconds: 10),
            );
            while (!io.File(armedPath).existsSync() &&
                DateTime.now().isBefore(armedDeadline)) {
              await Future<void>.delayed(const Duration(milliseconds: 50));
            }
            expect(io.File(armedPath).existsSync(), isTrue);

            parent.kill();
            await parent.exitCode;
            final exitCode = await worker.exitCode;
            expect(exitCode, 0);
            expect(io.File(targetPath).existsSync(), isFalse);
          } finally {
            lock?.closeSync();
            try {
              parent.kill();
            } on Object {
              // Already gone; nothing left to clean up.
            }
            try {
              worker.kill();
            } on Object {
              // Already gone; nothing left to clean up.
            }
          }
        },
        skip: io.Platform.isWindows
            ? false
            : 'provokes a real Windows sharing violation through the real '
                  'worker script',
        timeout: const Timeout(Duration(seconds: 40)),
      );

      test(
        'the abandon rename keeps retrying a real sharing violation on the '
        'ready marker well past a short stand-in for the old cap, and still '
        'succeeds once it clears',
        () async {
          final readyPath = '${tempDir.path}${io.Platform.pathSeparator}ready';
          final abandonedPath =
              '${tempDir.path}${io.Platform.pathSeparator}abandoned';
          const oldCapStandIn = Duration(seconds: 5);

          final parent = await io.Process.start('powershell', [
            '-NoProfile',
            '-NonInteractive',
            '-Command',
            'Start-Sleep -Seconds 60',
          ]);

          final nowUnixMs = DateTime.now().toUtc().millisecondsSinceEpoch;
          // The claim deadline is set generously ahead so it only passes,
          // and the worker only attempts its first abandon rename, well
          // after this test has already had time to detect the ready marker
          // and lock it: otherwise the worker could reach that first attempt
          // in the same instant it creates the marker, before this test
          // could ever react.
          final worker = await _startWorkerProcess({
            'parentPid': parent.pid,
            'paths': <String>[],
            'markerDeadlineUnixMs': nowUnixMs + 30000,
            'claimDeadlineUnixMs': nowUnixMs + 3000,
          }, readyPath);

          io.RandomAccessFile? lock;
          try {
            final readyDeadline = DateTime.now().add(
              const Duration(seconds: 20),
            );
            while (!io.File(readyPath).existsSync() &&
                DateTime.now().isBefore(readyDeadline)) {
              await Future<void>.delayed(const Duration(milliseconds: 5));
            }
            expect(io.File(readyPath).existsSync(), isTrue);

            lock = io.File(readyPath).openSync(mode: io.FileMode.write);

            // Held well past the claim deadline (3s from launch) plus the
            // old cap stand-in, so the worker's own retried abandon rename
            // has every opportunity to give up if it still could.
            await Future<void>.delayed(
              oldCapStandIn + const Duration(seconds: 3),
            );
            expect(
              await _isStillRunning(worker),
              isTrue,
              reason:
                  'a worker retrying an unexpected abandon-rename failure '
                  'with no cap of its own must still be alive well past both '
                  'its own claim deadline and any short interval that used '
                  'to be enough to make it give up',
            );
            expect(io.File(abandonedPath).existsSync(), isFalse);

            lock.closeSync();
            lock = null;

            final exitCode = await worker.exitCode;
            expect(exitCode, 0);
            expect(io.File(abandonedPath).existsSync(), isTrue);
          } finally {
            lock?.closeSync();
            try {
              parent.kill();
            } on Object {
              // Already gone; nothing left to clean up.
            }
            try {
              worker.kill();
            } on Object {
              // Already gone; nothing left to clean up.
            }
          }
        },
        skip: io.Platform.isWindows
            ? false
            : 'provokes a real Windows sharing violation through the real '
                  'worker script',
        timeout: const Timeout(Duration(seconds: 40)),
      );

      // Every rename in the protocol above rides out an unexpected failure
      // through Complete-Rename's own indefinite retry. The final deletion
      // steps are the one place in the real, unmodified script that never
      // went through that helper at all: this proves deleting the target
      // must retry a real sharing violation the same way, instead of
      // letting an unhandled exception there kill the worker before the
      // target is ever removed.
      test(
        'deleting the target path keeps retrying a real sharing violation '
        'well past a short stand-in for the old cap, and still succeeds '
        'once it clears',
        () async {
          final readyPath = '${tempDir.path}${io.Platform.pathSeparator}ready';
          final acceptedPath =
              '${tempDir.path}${io.Platform.pathSeparator}accepted';
          final armedPath = '${tempDir.path}${io.Platform.pathSeparator}armed';
          final targetPath =
              '${tempDir.path}${io.Platform.pathSeparator}victim.txt';
          io.File(targetPath).writeAsStringSync('gone soon');
          const oldGapStandIn = Duration(seconds: 5);

          final parent = await io.Process.start('powershell', [
            '-NoProfile',
            '-NonInteractive',
            '-Command',
            'Start-Sleep -Seconds 60',
          ]);

          final nowUnixMs = DateTime.now().toUtc().millisecondsSinceEpoch;
          final worker = await _startWorkerProcess({
            'parentPid': parent.pid,
            'paths': [targetPath],
            'markerDeadlineUnixMs': nowUnixMs + 30000,
            'claimDeadlineUnixMs': nowUnixMs + 30000,
          }, readyPath);

          // Drained, not asserted on: this test is the one real-script case
          // that deliberately provokes a genuine PowerShell error record (a
          // sharing violation on the delete step), and its CLIXML rendering
          // on stderr is large enough that, left unread, it can fill the
          // pipe buffer and block the worker on the write itself, which
          // would masquerade as this test's own retry-survival signal for
          // the wrong reason.
          unawaited(worker.stdout.drain<void>());
          unawaited(worker.stderr.drain<void>());

          io.RandomAccessFile? lock;
          try {
            final readyDeadline = DateTime.now().add(
              const Duration(seconds: 20),
            );
            while (!io.File(readyPath).existsSync() &&
                DateTime.now().isBefore(readyDeadline)) {
              await Future<void>.delayed(const Duration(milliseconds: 5));
            }
            expect(io.File(readyPath).existsSync(), isTrue);

            // This test's own claim: the exact retrying claim
            // IoCliProcessLauncher.startCleanupWorker itself performs.
            expect(
              await _claimReadyMarkerForTest(readyPath, acceptedPath),
              isTrue,
            );

            // Nothing contests the arm rename here, so the worker wins it
            // immediately and then blocks on $parent.WaitForExit(), which
            // this test's own real, still-alive parent keeps it blocked on
            // until killed below.
            final armedDeadline = DateTime.now().add(
              const Duration(seconds: 10),
            );
            while (!io.File(armedPath).existsSync() &&
                DateTime.now().isBefore(armedDeadline)) {
              await Future<void>.delayed(const Duration(milliseconds: 20));
            }
            expect(io.File(armedPath).existsSync(), isTrue);

            // Locked only once armed, and before the parent is killed: by
            // the time WaitForExit() returns below, the lock has already
            // been in place for the whole delete step, so there is no
            // timing window for it to slip through unlocked.
            lock = io.File(targetPath).openSync(mode: io.FileMode.write);

            parent.kill();
            await parent.exitCode;

            // Held well past any short interval that would already have
            // made a single, unretried delete attempt give up.
            await Future<void>.delayed(
              oldGapStandIn + const Duration(seconds: 3),
            );
            expect(
              await _isStillRunning(worker),
              isTrue,
              reason:
                  'a worker retrying an unexpected deletion failure with no '
                  'cap of its own must still be alive well past any short '
                  'interval that would already have made a single, '
                  'unretried attempt give up',
            );
            expect(io.File(targetPath).existsSync(), isTrue);

            lock.closeSync();
            lock = null;

            final exitCode = await worker.exitCode.timeout(
              const Duration(seconds: 10),
            );
            expect(exitCode, 0);
            expect(io.File(targetPath).existsSync(), isFalse);
          } finally {
            lock?.closeSync();
            try {
              parent.kill();
            } on Object {
              // Already gone; nothing left to clean up.
            }
            try {
              worker.kill();
            } on Object {
              // Already gone; nothing left to clean up.
            }
          }
        },
        skip: io.Platform.isWindows
            ? false
            : 'provokes a real Windows sharing violation through the real '
                  'worker script',
        timeout: const Timeout(Duration(seconds: 40)),
      );
    },
  );

  // Round 8 finding 4: the previous version of this test only ever
  // exercised the real, always-unbounded script, so a reintroduced cap
  // would have passed it just as easily as no cap at all (the
  // "oldCapStandIn" it used only sized how long the test itself waited,
  // never anything the script's own behaviour was driven by). It proved
  // nothing about a cap actually being absent. This gives the contrast that
  // was missing: a deliberately bounded stand-in, built by substituting the
  // real script's own unbounded $parent.WaitForExit() call for a short,
  // self-marking bounded one, is shown to actually give up on a still-alive
  // parent once its own cap elapses, before contrasting it with the real
  // script staying alive well past that same mark on an equally-alive
  // parent.
  group('the removed unbounded-wait cap actually mattered', () {
    late io.Directory tempDir;

    setUp(() {
      tempDir = io.Directory.systemTemp.createTempSync('legacy_cap_test_');
    });

    tearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    test(
      'a legacy-capped stand-in of the real script, built by substituting '
      'its own unbounded wait for a short bounded one, gives up on a '
      'still-alive parent once its own cap elapses',
      () async {
        const legacyCapMs = 300;
        final gaveUpPath = '${tempDir.path}${io.Platform.pathSeparator}gave-up';
        final legacyScript = cleanupWorkerBootstrapScript.replaceFirst(
          r'$parent.WaitForExit()',
          '''
if (-not \$parent.WaitForExit($legacyCapMs)) {
    [System.IO.File]::WriteAllText((Join-Path \$PrivateDir 'gave-up'), '')
    exit 1
}
''',
        );
        expect(
          legacyScript,
          isNot(cleanupWorkerBootstrapScript),
          reason: 'the substitution must actually have matched something',
        );

        final readyPath = '${tempDir.path}${io.Platform.pathSeparator}ready';
        final targetPath =
            '${tempDir.path}${io.Platform.pathSeparator}victim.txt';
        io.File(targetPath).writeAsStringSync('gone soon');

        // Round 9 finding 3: a fixed parent lifetime made this comparison
        // nondeterministic, since worker readiness (the poll below already
        // allows it up to 20s) could take long enough that a fixed-length
        // parent had already exited on its own by the time this test
        // reached its own assertions, for reasons having nothing to do
        // with the bounded-wait branch this test means to exercise. Kept
        // alive behind an explicit release signal instead, released only
        // once every assertion that depends on it still being alive is
        // done.
        final releaseParentPath =
            '${tempDir.path}${io.Platform.pathSeparator}release-parent';
        final parent = await _startReleasableParent(releaseParentPath);

        final nowUnixMs = DateTime.now().toUtc().millisecondsSinceEpoch;
        final worker = await _startWorkerProcess(
          {
            'parentPid': parent.pid,
            'paths': [targetPath],
            'markerDeadlineUnixMs': nowUnixMs + 30000,
            'claimDeadlineUnixMs': nowUnixMs + 30000,
          },
          readyPath,
          encodedScript: _encodeScriptForPowerShell(legacyScript),
        );

        final acceptedPath =
            '${tempDir.path}${io.Platform.pathSeparator}'
            '$cleanupWorkerAcceptedMarkerFileName';

        try {
          final readyDeadline = DateTime.now().add(const Duration(seconds: 20));
          while (!io.File(readyPath).existsSync() &&
              DateTime.now().isBefore(readyDeadline)) {
            await Future<void>.delayed(cleanupWorkerReadyPollInterval);
          }
          expect(io.File(readyPath).existsSync(), isTrue);
          // Simulates the CLI's own Phase 1 claim, which this direct
          // launch bypasses: without it the worker would simply wait out
          // its own (generously far off) claim deadline and abandon,
          // instead of ever reaching the arm rename and bounded wait this
          // test means to exercise.
          expect(
            await _claimReadyMarkerForTest(readyPath, acceptedPath),
            isTrue,
          );

          final exitCode = await worker.exitCode.timeout(
            const Duration(seconds: 20),
          );
          expect(
            exitCode,
            1,
            reason: 'the legacy-capped stand-in must give up, not succeed',
          );
          expect(
            io.File(gaveUpPath).existsSync(),
            isTrue,
            reason:
                'proves it gave up specifically through the bounded-wait '
                'branch, not some unrelated failure',
          );
          expect(
            io.File(targetPath).existsSync(),
            isTrue,
            reason: 'a worker that gave up must delete nothing',
          );
        } finally {
          // Every assertion depending on the parent still being alive is
          // done; let it exit rather than leaving it to a bare kill. The
          // bounded-wait branch this test provokes always exits before
          // ever arming, so, unlike the contrasting test below, this
          // worker never deletes tempDir itself; the existence check is
          // kept anyway so both finally blocks read the same way.
          if (!io.File(releaseParentPath).existsSync() &&
              tempDir.existsSync()) {
            io.File(releaseParentPath).createSync();
          }
          try {
            parent.kill();
          } on Object {
            // Already gone; nothing left to clean up.
          }
        }
      },
      skip: io.Platform.isWindows
          ? false
          : 'launches a real Windows PowerShell process',
      timeout: const Timeout(Duration(seconds: 40)),
    );

    test(
      'the real, unmodified script has no such cap: it keeps waiting on '
      'the same still-alive parent well past where the stand-in above '
      'already gave up, and only deletes once the parent actually exits',
      () async {
        const legacyCapMs = 300;
        final readyPath = '${tempDir.path}${io.Platform.pathSeparator}ready';
        final targetPath =
            '${tempDir.path}${io.Platform.pathSeparator}victim.txt';
        io.File(targetPath).writeAsStringSync('gone soon');

        // Round 9 finding 3: same nondeterminism as the stand-in test
        // above, and the same fix: a release signal in place of a fixed
        // lifetime, released only once the assertions that depend on the
        // parent still being alive, and on the real script's wait staying
        // unbounded, are both done.
        final releaseParentPath =
            '${tempDir.path}${io.Platform.pathSeparator}release-parent';
        final parent = await _startReleasableParent(releaseParentPath);

        final nowUnixMs = DateTime.now().toUtc().millisecondsSinceEpoch;
        final worker = await _startWorkerProcess({
          'parentPid': parent.pid,
          'paths': [targetPath],
          'markerDeadlineUnixMs': nowUnixMs + 30000,
          'claimDeadlineUnixMs': nowUnixMs + 30000,
        }, readyPath);

        final acceptedPath =
            '${tempDir.path}${io.Platform.pathSeparator}'
            '$cleanupWorkerAcceptedMarkerFileName';

        try {
          final readyDeadline = DateTime.now().add(const Duration(seconds: 20));
          while (!io.File(readyPath).existsSync() &&
              DateTime.now().isBefore(readyDeadline)) {
            await Future<void>.delayed(cleanupWorkerReadyPollInterval);
          }
          expect(io.File(readyPath).existsSync(), isTrue);
          // Simulates the CLI's own Phase 1 claim, the same way the
          // stand-in test above does, so the real script also reaches its
          // arm rename and its own (unbounded) wait rather than abandoning
          // once its own claim deadline passes.
          expect(
            await _claimReadyMarkerForTest(readyPath, acceptedPath),
            isTrue,
          );

          await Future<void>.delayed(
            const Duration(milliseconds: legacyCapMs * 4),
          );
          expect(
            await _isStillRunning(worker),
            isTrue,
            reason:
                'the real script must still be waiting well past the same '
                'cap the legacy stand-in already gave up at above',
          );
          expect(io.File(targetPath).existsSync(), isTrue);

          // Only now released: the worker's own unbounded
          // $parent.WaitForExit() call must still be genuinely blocked on
          // it, proven above, not something a fixed sleep merely hoped
          // would still be true by this point.
          io.File(releaseParentPath).createSync();
          await parent.exitCode;
          final exitCode = await worker.exitCode.timeout(
            const Duration(seconds: 20),
          );
          expect(exitCode, 0);
          expect(io.File(targetPath).existsSync(), isFalse);
        } finally {
          // Idempotent, and skipped entirely once the run above already
          // reached its own release: by then the armed worker has gone on
          // to delete its own private directory (this test's tempDir)
          // once the parent it was waiting on exited, so a second,
          // unconditional creation attempt here would find that directory
          // already gone rather than merely find the marker already
          // present.
          if (!io.File(releaseParentPath).existsSync() &&
              tempDir.existsSync()) {
            io.File(releaseParentPath).createSync();
          }
          try {
            parent.kill();
          } on Object {
            // Already gone; nothing left to clean up.
          }
          try {
            worker.kill();
          } on Object {
            // Already gone; nothing left to clean up.
          }
        }
      },
      skip: io.Platform.isWindows
          ? false
          : 'launches a real Windows PowerShell process',
      timeout: const Timeout(Duration(seconds: 40)),
    );
  });
}

/// Starts a real, non-detached PowerShell process running [encodedScript]
/// with [payload] and [readyMarkerPath] wired the same way
/// [IoCliProcessLauncher.startCleanupWorker] itself wires them, but launched
/// directly (no `cmd.exe` `start` hand-off) so a test keeps a live handle to
/// the real worker process and can observe its actual exit, not merely a
/// launcher's. [encodedScript] defaults to the real, unmodified
/// [cleanupWorkerEncodedBootstrapScript]; passing a different one exercises
/// a deliberately modified stand-in against the same real payload wiring.
/// Bypassing the launcher class here is deliberate: these tests are about
/// the worker script's own retry behaviour, not about the CLI-side launch
/// and job-object escape mechanics, which are covered elsewhere.
Future<io.Process> _startWorkerProcess(
  Map<String, Object?> payload,
  String readyMarkerPath, {
  String? encodedScript,
}) {
  final environment = io.Platform.environment;
  final powershellPath = powershellExecutablePath(environment);
  final workerEnvironment = Map<String, String>.from(environment)
    ..[cleanupWorkerPayloadEnvVar] = jsonEncode(payload)
    ..[cleanupWorkerReadyMarkerPathEnvVar] = readyMarkerPath;
  return io.Process.start(
    powershellPath,
    [
      '-NoProfile',
      '-NonInteractive',
      '-EncodedCommand',
      encodedScript ?? cleanupWorkerEncodedBootstrapScript,
    ],
    environment: workerEnvironment,
    mode: io.ProcessStartMode.normal,
  );
}

/// Whether [process] is still running, checked without ever pausing on a
/// fixed sleep: [io.Process.exitCode] returns the same future on every
/// call, so racing it against a short timer either resolves through the
/// process having actually exited, or through the timer, meaning the
/// process is still alive.
Future<bool> _isStillRunning(io.Process process) => Future.any([
  process.exitCode.then((_) => false),
  Future<bool>.delayed(const Duration(milliseconds: 100), () => true),
]);

/// Base64-encodes [script] as UTF-16LE, the same encoding
/// [cleanupWorkerEncodedBootstrapScript] uses for the real script, so a test
/// can hand PowerShell's own `-EncodedCommand` a deliberately modified
/// stand-in through [_startWorkerProcess]. Kept local to this test:
/// production's own encoding helper is private to the production file.
String _encodeScriptForPowerShell(String script) {
  final bytes = <int>[];
  for (final unit in script.codeUnits) {
    bytes.add(unit & 0xFF);
    bytes.add((unit >> 8) & 0xFF);
  }
  return base64.encode(bytes);
}

/// A real [IoCliProcessLauncher] whose [deletePrivateDirectory] seam always
/// throws [cleanupError] in place of actually removing the private
/// directory. Overriding this one method, rather than the whole class,
/// exercises startCleanupWorker's own handling of a real cleanup failure,
/// folded into the thrown [CliCleanupWorkerStartFailure]'s message, through
/// the real adapter, since nothing portable lets a test provoke a real
/// directory-deletion failure at exactly this point otherwise. Production
/// code never overrides this.
class _FailingCleanupDirectoryLauncher extends IoCliProcessLauncher {
  _FailingCleanupDirectoryLauncher(
    this.cleanupError, {
    super.startupTimeout = cleanupWorkerStartupTimeout,
  });

  final Object cleanupError;

  @override
  void deletePrivateDirectory(io.Directory privateDir) {
    throw cleanupError;
  }
}

/// Decodes UTF-16LE [bytes] to UTF-16 code units. The inverse of the
/// encoding [cleanupWorkerEncodedBootstrapScript] uses, kept local to this
/// test: production code never needs to decode its own encoded command back.
List<int> _decodeUtf16Le(List<int> bytes) {
  final units = <int>[];
  for (var i = 0; i + 1 < bytes.length; i += 2) {
    units.add(bytes[i] | (bytes[i + 1] << 8));
  }
  return units;
}
