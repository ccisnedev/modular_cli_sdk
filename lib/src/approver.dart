import 'dart:io' as io;

/// Asks a human whether the shown plan may be carried out.
///
/// Injected on [ModularCli] so tests can answer without a terminal, and so the
/// decision of *how* to ask stays out of every command.
typedef Approver = Future<bool> Function(String renderedPlan);

/// Thrown when `--apply` needs an approval and no terminal can give one.
class NoApproverAvailable implements Exception {
  const NoApproverAvailable();

  String get message =>
      'No terminal to approve from. Pass --autoapprove to act without '
      'asking — that is the invocation for agents and CI, and it records in '
      'the command line that the approval was given in advance.';

  @override
  String toString() => message;
}

/// The default [Approver]: prints the plan and reads one line from stdin.
///
/// When there is nobody to answer, blocking on a read that will never return is
/// the one failure mode this has to prevent. So it refuses instead of hanging,
/// and names the flag that resolves it. An agent that forgot `--autoapprove`
/// gets a message; it does not get a process that never exits.
///
/// Two things have to be treated as "nobody there", not one. `stdin.hasTerminal`
/// is the cheap check, but it is not sufficient: a process whose stdout is piped
/// can still report a terminal and then fail on the read itself — on Windows,
/// with `StdinException: Error getting terminal line mode`. The read is
/// therefore guarded too. Anything that stops an answer from arriving means the
/// same thing, so it produces the same refusal.
class ConsoleApprover {
  ConsoleApprover({
    io.IOSink? out,
    bool Function()? hasTerminal,
    String Function()? readLine,
  }) : out = out ?? io.stderr,
       hasTerminal = hasTerminal ?? (() => io.stdin.hasTerminal),
       readLine = readLine ?? (() => io.stdin.readLineSync() ?? '');

  final io.IOSink out;
  final bool Function() hasTerminal;
  final String Function() readLine;

  Future<bool> call(String renderedPlan) async {
    out
      ..writeln(renderedPlan)
      ..writeln();

    if (!hasTerminal()) throw const NoApproverAvailable();

    out.write('Apply this plan? [y/N] ');

    final String answer;
    try {
      answer = readLine().trim().toLowerCase();
    } on Object {
      // The terminal said it was there and then would not be read from. That is
      // still nobody to approve, and it must not surface as a crash: a stack
      // trace on a command that changed nothing reads like a failure to act
      // rather than a refusal to.
      out.writeln();
      throw const NoApproverAvailable();
    }

    return answer == 'y' || answer == 'yes';
  }
}
