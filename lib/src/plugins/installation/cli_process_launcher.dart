import 'dart:io' as io;

/// The process identity and detached-process-launching capability
/// [SelfDeleteExecutableStep] needs to remove a running Windows executable.
/// Injectable for the same reason [CliFileSystem] is: a test supplies a fake
/// that records what was launched, in place of actually launching a `cmd.exe`
/// and waiting on a real PID.
abstract class CliProcessLauncher {
  /// This process's own process id.
  int get currentPid;

  /// Starts [executable] with [arguments], detached from this process: it
  /// keeps running after this process exits, and this process does not wait
  /// on it. Throws when the process cannot be started at all (the executable
  /// is missing, the platform refuses); a process that starts and then fails
  /// on its own is not this method's concern.
  Future<void> start(String executable, List<String> arguments);
}

/// Launches a real, detached OS process.
class IoCliProcessLauncher implements CliProcessLauncher {
  const IoCliProcessLauncher();

  @override
  int get currentPid => io.pid;

  @override
  Future<void> start(String executable, List<String> arguments) async {
    await io.Process.start(
      executable,
      arguments,
      mode: io.ProcessStartMode.detached,
    );
  }
}
