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
        cleanupWorkerAbandonedMarkerFileName,
        cleanupWorkerAcceptedMarkerFileName,
        cleanupWorkerArmedMarkerFileName,
        cleanupWorkerCmdCommandLine,
        cleanupWorkerEncodedBootstrapScript,
        cleanupWorkerFailedMarkerFileName,
        cleanupWorkerReadyMarkerFileName,
        cleanupWorkerRevokedMarkerFileName,
        pollForArm,
        pollForClaim,
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
    .where((path) => path.split(io.Platform.pathSeparator).last.startsWith(
          'cli_cleanup_',
        ))
    .toSet();

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

    test(
      'signals readiness through a marker file named by an environment '
      'variable, created without recreating a missing parent directory',
      () {
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
      },
    );

    // Round 6 finding 2: PowerShell 5.1's own $parent.Handle property-getter
    // syntax has been observed to return $null instead of throwing for an
    // access-denied process, even under $ErrorActionPreference = 'Stop'.
    // get_Handle(), the explicit method-call form of the same accessor, is
    // what the worker uses instead, precisely so a failure to retain the
    // handle cannot be missed this way.
    test(
      'retains a handle on the parent process, via the explicit '
      'get_Handle() accessor rather than the Handle property, before '
      'signalling ready',
      () {
        expect(cleanupWorkerBootstrapScript, contains('GetProcessById'));
        expect(cleanupWorkerBootstrapScript, contains(r'$parent.get_Handle()'));
        expect(
          cleanupWorkerBootstrapScript,
          isNot(contains(r'$parent.Handle')),
        );
        final markerIndex = cleanupWorkerBootstrapScript.indexOf(
          '[System.IO.FileMode]::CreateNew',
        );
        final handleIndex = cleanupWorkerBootstrapScript.indexOf(
          r'$parent.get_Handle()',
        );
        expect(handleIndex, greaterThanOrEqualTo(0));
        expect(markerIndex, greaterThan(handleIndex));
      },
    );

    // Round 6 finding 2: get_Handle() alone is not enough, since it is the
    // same underlying accessor that can silently return $null; the worker
    // must also explicitly reject a null or zero handle itself, before the
    // ready marker exists, rather than trust a value that a null handle
    // would let through unnoticed.
    test(
      'explicitly rejects a null or zero handle, before the ready marker '
      'is created, rather than trusting whatever get_Handle() returned',
      () {
        expect(
          cleanupWorkerBootstrapScript,
          contains('[IntPtr]::Zero'),
        );
        expect(
          cleanupWorkerBootstrapScript,
          contains(r'$null -eq $handle'),
        );
        final validationIndex = cleanupWorkerBootstrapScript.indexOf(
          '[IntPtr]::Zero',
        );
        final markerIndex = cleanupWorkerBootstrapScript.indexOf(
          '[System.IO.FileMode]::CreateNew',
        );
        expect(validationIndex, greaterThanOrEqualTo(0));
        expect(markerIndex, greaterThan(validationIndex));
      },
    );

    // Round 5 finding 1: GetProcessById throwing System.ArgumentException
    // means no such process exists, which is genuinely "the parent already
    // exited" and safe to treat as $parent = $null. Any other failure
    // retaining a handle on a process that does exist (most notably,
    // access denied on .Handle itself for a protected process) must not be
    // folded into that same "already exited" outcome: it has to stop the
    // worker before the ready marker is created, so the CLI sees no marker
    // in time and reports cleanup-start-failed instead of a worker that
    // silently is not actually holding what it needs.
    test(
      'catches only ArgumentException around GetProcessById, so a '
      'different failure retaining the handle is not folded into '
      '"parent already exited"',
      () {
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
      },
    );

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
    test(
      'reads its own copy of the CLI\'s absolute claim deadline from the '
      'payload, separately from the marker-creation deadline',
      () {
        expect(cleanupWorkerBootstrapScript, contains('claimDeadlineUnixMs'));
        expect(
          cleanupWorkerBootstrapScript,
          contains('markerDeadlineUnixMs'),
        );
      },
    );

    test(
      'computes the accepted and abandoned marker paths as siblings of the '
      'ready marker, named by the protocol\'s own state constants',
      () {
        expect(
          cleanupWorkerBootstrapScript,
          contains("Join-Path \$PrivateDir '$cleanupWorkerAcceptedMarkerFileName'"),
        );
        expect(
          cleanupWorkerBootstrapScript,
          contains("Join-Path \$PrivateDir '$cleanupWorkerAbandonedMarkerFileName'"),
        );
      },
    );

    test(
      'claims abandonment through an atomic rename, only after the ready '
      'marker was created, not instead of waiting for the CLI to claim it '
      'first',
      () {
        expect(
          cleanupWorkerBootstrapScript,
          contains('[System.IO.File]::Move('),
        );
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
      },
    );

    // Round 7 finding 1: a dead worker's ready marker still being claimed
    // by the CLI must not, on its own, arm anything. Merely observing that
    // the accepted marker exists is no longer enough; the worker has to
    // actually win its own atomic rename of it to the armed marker first.
    test(
      'arms deletion only by winning an atomic rename of the accepted '
      'marker to the armed marker, never merely by observing that the '
      'accepted marker exists',
      () {
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
      },
    );

    test(
      'computes the armed marker path as a sibling of the ready marker, '
      'named by the protocol\'s own state constant',
      () {
        expect(
          cleanupWorkerBootstrapScript,
          contains("Join-Path \$PrivateDir '$cleanupWorkerArmedMarkerFileName'"),
        );
      },
    );

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
    // the retry, typed-loss and failure-marker logic exists exactly once,
    // short enough to stay well under cmd.exe's command-line limit even
    // after Phase 2 grew the script). This checks the helper itself retries
    // an unexpected failure rather than giving up the moment the first
    // attempt fails, distinguishing that from the legitimate loss of the
    // source already being gone, and that both call sites actually go
    // through it.
    test(
      'retries an unexpected rename failure on the same poll interval, '
      'through the one shared helper both the abandon and the arm rename '
      'call, rather than giving up the moment the first attempt fails',
      () {
        final functionIndex = cleanupWorkerBootstrapScript.indexOf(
          'function Complete-Rename',
        );
        final typedCatchIndex = cleanupWorkerBootstrapScript.indexOf(
          'catch [System.IO.FileNotFoundException]',
          functionIndex,
        );
        final ackDeadlineIndex = cleanupWorkerBootstrapScript.indexOf(
          'ackDeadlineUnixMs',
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
        expect(
          ackDeadlineIndex,
          greaterThan(functionIndex),
          reason:
              'an unexpected rename failure is retried until the ack '
              'deadline, not given up on immediately',
        );
        expect(abandonCallIndex, greaterThan(functionIndex));
        expect(armCallIndex, greaterThan(functionIndex));
      },
    );

    test(
      'records a named failure marker, best effort, when a retried rename '
      'never succeeds before the ack deadline, rather than exiting with no '
      'trace of which case this was',
      () {
        expect(
          cleanupWorkerBootstrapScript,
          contains("Join-Path \$PrivateDir '$cleanupWorkerFailedMarkerFileName'"),
        );
        final failedPathOccurrences = RegExp(
          r'\$FailedMarkerPath',
        ).allMatches(cleanupWorkerBootstrapScript).length;
        expect(
          failedPathOccurrences,
          greaterThanOrEqualTo(2),
          reason:
              'declared once, then written from within the one shared '
              'retry helper both the abandon and the arm rename call '
              'through',
        );
      },
    );

    // Round 7 finding 3: the worker must wait for the parent with no time
    // limit at all once armed, not a bounded wait that can give up while
    // the parent is merely slow to exit. There is no timeoutMs field left
    // in the payload for a bound to even come from.
    test(
      'waits for the parent with the parameterless, unbounded '
      'WaitForExit(), never the bounded overload, and reads no timeoutMs '
      'from the payload at all',
      () {
        expect(cleanupWorkerBootstrapScript, contains(r'$parent.WaitForExit()'));
        expect(
          cleanupWorkerBootstrapScript,
          isNot(contains(r'$parent.WaitForExit($timeoutMs)')),
        );
        expect(cleanupWorkerBootstrapScript, isNot(contains('timeoutMs')));
      },
    );

    test(
      'reads its own copy of the CLI\'s ack deadline from the payload, '
      'separately from the claim deadline',
      () {
        expect(cleanupWorkerBootstrapScript, contains('ackDeadlineUnixMs'));
        expect(cleanupWorkerBootstrapScript, contains('claimDeadlineUnixMs'));
      },
    );

    test(
      'deletes its own private directory only once armed, after deleting '
      'the target paths, so that responsibility never depends on the CLI '
      'having already removed it before the worker could observe the '
      'claim it won',
      () {
        final armedIndex = cleanupWorkerBootstrapScript.indexOf(
          r'if ($armed) {',
        );
        final removeTargetIndex = cleanupWorkerBootstrapScript.indexOf(
          r'Remove-Item -LiteralPath $path',
        );
        final removePrivateDirIndex = cleanupWorkerBootstrapScript.indexOf(
          r'Remove-Item -LiteralPath $PrivateDir -Recurse',
        );
        expect(armedIndex, greaterThanOrEqualTo(0));
        expect(removeTargetIndex, greaterThan(armedIndex));
        expect(removePrivateDirIndex, greaterThan(removeTargetIndex));
      },
    );

    test('waits for the parent to exit before deleting anything', () {
      expect(cleanupWorkerBootstrapScript, contains('WaitForExit'));
      final waitIndex = cleanupWorkerBootstrapScript.indexOf('WaitForExit');
      final removeTargetIndex = cleanupWorkerBootstrapScript.indexOf(
        r'Remove-Item -LiteralPath $path',
      );
      expect(removeTargetIndex, greaterThan(waitIndex));
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

    test(
      'renames the ready marker to accepted and returns true when it '
      'exists',
      () {
        final readyPath = '${tempDir.path}${io.Platform.pathSeparator}ready';
        final acceptedPath =
            '${tempDir.path}${io.Platform.pathSeparator}accepted';
        io.File(readyPath).createSync();

        expect(tryClaimReadyMarker(readyPath, acceptedPath), isTrue);
        expect(io.File(acceptedPath).existsSync(), isTrue);
        expect(io.File(readyPath).existsSync(), isFalse);
      },
    );

    test(
      'returns false, creating nothing, when the ready marker was never '
      'created',
      () {
        final readyPath = '${tempDir.path}${io.Platform.pathSeparator}ready';
        final acceptedPath =
            '${tempDir.path}${io.Platform.pathSeparator}accepted';

        expect(tryClaimReadyMarker(readyPath, acceptedPath), isFalse);
        expect(io.File(acceptedPath).existsSync(), isFalse);
      },
    );

    test(
      'loses the claim when the worker already renamed the ready marker '
      'to abandoned first',
      () {
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
      },
    );

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

    test(
      'renames the accepted marker to revoked and returns true when it '
      'exists',
      () {
        final acceptedPath =
            '${tempDir.path}${io.Platform.pathSeparator}accepted';
        final revokedPath =
            '${tempDir.path}${io.Platform.pathSeparator}$cleanupWorkerRevokedMarkerFileName';
        io.File(acceptedPath).createSync();

        expect(tryRevokeAcceptedMarker(acceptedPath, revokedPath), isTrue);
        expect(io.File(revokedPath).existsSync(), isTrue);
        expect(io.File(acceptedPath).existsSync(), isFalse);
      },
    );

    test(
      'returns false, creating nothing, when the accepted marker does not '
      'exist',
      () {
        final acceptedPath =
            '${tempDir.path}${io.Platform.pathSeparator}accepted';
        final revokedPath =
            '${tempDir.path}${io.Platform.pathSeparator}$cleanupWorkerRevokedMarkerFileName';

        expect(tryRevokeAcceptedMarker(acceptedPath, revokedPath), isFalse);
        expect(io.File(revokedPath).existsSync(), isFalse);
      },
    );

    // Revoke-vs-arm race, direction 1: the worker wins by renaming
    // accepted to armed first. The CLI's own revoke attempt, arriving
    // after, must lose cleanly.
    test(
      'loses the race when the worker already renamed the accepted marker '
      'to armed first',
      () {
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
      },
    );

    // Revoke-vs-arm race, direction 2: the CLI wins by renaming accepted
    // to revoked first. The worker's own later arm rename, arriving after,
    // must lose cleanly (a legitimate "source not found" loss, exactly
    // what tells the worker to exit without deleting).
    test(
      'wins the race before the worker gets a chance to arm, so a late '
      'arm rename attempt afterwards fails because the source is already '
      'gone',
      () {
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
      },
    );

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

    test(
      'observes an armed marker the worker already created, even on its '
      'very first check',
      () async {
        final armedPath = '${tempDir.path}${io.Platform.pathSeparator}armed';
        io.File(armedPath).createSync();

        final armed = await pollForArm(
          armedMarkerPath: armedPath,
          deadline: DateTime.now().add(const Duration(milliseconds: 30)),
          pollInterval: const Duration(milliseconds: 5),
          now: DateTime.now,
        );

        expect(armed, isTrue);
      },
    );

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

    test(
      'a worker that creates its ready marker and then goes silent '
      'forever, crashed or killed before ever reaching the accepted '
      'marker, is never reported as scheduled: winning the Phase 1 claim '
      'alone is not enough, and the Phase 2 ack deadline revokes it '
      'instead',
      () async {
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

        final revoked = tryRevokeAcceptedMarker(acceptedPath, revokedPath);
        expect(
          revoked,
          isTrue,
          reason:
              'nothing was left to contest the revoke, so it wins, exactly '
              'the signal IoCliProcessLauncher.startCleanupWorker uses to '
              'report failure instead of a false success',
        );
        expect(io.File(revokedPath).existsSync(), isTrue);
        expect(io.File(armedPath).existsSync(), isFalse);
      },
    );
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
    test(
      'wins on its very first attempt even when its own clock already '
      'reads past the deadline, so a CLI that resumes suspended past its '
      'deadline still claims a marker the worker created in time',
      () async {
        final readyPath = '${tempDir.path}${io.Platform.pathSeparator}ready';
        final acceptedPath =
            '${tempDir.path}${io.Platform.pathSeparator}accepted';
        io.File(readyPath).createSync();
        final pastDeadline = DateTime.now().subtract(
          const Duration(seconds: 1),
        );

        final claimed = await pollForClaim(
          readyMarkerPath: readyPath,
          acceptedMarkerPath: acceptedPath,
          deadline: pastDeadline,
          pollInterval: const Duration(milliseconds: 5),
          now: DateTime.now,
        );

        expect(claimed, isTrue);
        expect(io.File(acceptedPath).existsSync(), isTrue);
      },
    );

    test(
      'gives up once the deadline passes when the ready marker never '
      'appears',
      () async {
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
      },
    );

    test(
      'gives up when the worker wins the claim first, even though the '
      'ready marker briefly existed',
      () async {
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
      },
    );

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

  test(
    'cleanupWorkerReadyMarkerFileName is the fixed literal the CLI and the '
    'worker both build the ready marker\'s path from',
    () {
      expect(cleanupWorkerReadyMarkerFileName, 'ready');
    },
  );

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
      test(
        'throws CliCleanupWorkerStartFailure when SystemRoot contains '
        '$metacharacter',
        () {
          expect(
            () => powershellExecutablePath({
              'SystemRoot': 'C:\\Windows${metacharacter}evil',
            }),
            throwsA(isA<CliCleanupWorkerStartFailure>()),
          );
        },
      );
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
        final helperScript = io.File(
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

        final helperScript = io.File(
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

        final helperScript = io.File(
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
          launcher.startCleanupWorker({
            'parentPid': 4,
            'paths': <String>[],
          }),
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
    // A real 5 minute parent is too slow to prove that in a test, so this
    // uses a parent that outlives a much shorter stand-in for the old cap
    // instead, and checks the worker is still waiting, not gone, well past
    // it.
    test(
      'an armed worker keeps waiting on its parent past any short interval '
      'that used to be enough to make it give up, proving there is no cap '
      'on how long it will wait',
      () async {
        final tempDir = io.Directory.systemTemp.createTempSync(
          'cleanup_worker_no_cap_test_',
        );
        addTearDown(() {
          if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
        });
        final targetPath =
            '${tempDir.path}${io.Platform.pathSeparator}victim.txt';
        io.File(targetPath).writeAsStringSync('gone soon');

        // Stands in for the old, removed 5 minute cap: a parent that
        // outlives this by a comfortable margin, with a checkpoint in
        // between, is enough to prove the worker never gives up on its
        // own.
        const oldCapStandIn = Duration(seconds: 5);

        final parent = await io.Process.start('powershell', [
          '-NoProfile',
          '-NonInteractive',
          '-Command',
          'Start-Sleep -Seconds 9',
        ]);

        try {
          const launcher = IoCliProcessLauncher();
          await launcher.startCleanupWorker({
            'parentPid': parent.pid,
            'paths': [targetPath],
          });

          await Future<void>.delayed(
            oldCapStandIn + const Duration(seconds: 2),
          );
          expect(
            io.File(targetPath).existsSync(),
            isTrue,
            reason:
                'the parent is still alive well past the old cap, so an '
                'armed worker with no timeout must still be waiting, not '
                'gone',
          );

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
  });
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
