/// A command that builds no steps can say why.
///
/// The framework knows *that* nothing would change. Only the command knows
/// *why*, and the why is the part a caller can act on. Two real CLIs had four
/// such messages — "Already on the latest version", "Latest release is a
/// prerelease — skipping.", "No AI coding host found on this machine …",
/// "No supported assistant found in your home directory." — and every one of
/// them was replaced by `nothing would change` the moment the empty plan
/// stopped reaching `describe`.
library;

import 'package:modular_cli_sdk/modular_cli_sdk.dart';
import 'package:test/test.dart';

import 'doubles.dart';

ModularCli _cliWith(TouchCommand command, {Approver? approver}) {
  final cli = ModularCli(approver: approver);
  cli.command<TouchInput, TouchOutput>(
    'touch',
    (req) => command,
    description: 'Touch things',
  );
  return cli;
}

TouchCommand _explaining(String? reason) =>
    TouchCommand(TouchInput(), targets: const [], explanation: reason);

void main() {
  group('a command explains its empty plan', () {
    test('--apply shows the reason instead of the framework wording', () async {
      final out = MemorySink();
      final code = await _cliWith(
        _explaining('Already on the latest version'),
      ).run(['touch', '--apply'], stdout: out);

      expect(code, ExitCode.ok);
      expect(out.output, contains('Already on the latest version'));
      expect(out.output, isNot(contains('nothing would change')));
    });

    // The gap this closes was widest here: `--plan` never called `describe`,
    // so an empty plan has always been mute — before the 0.5.0 change and
    // after it.
    test('--plan shows it too', () async {
      final out = MemorySink();
      final code = await _cliWith(
        _explaining('No AI coding host found on this machine'),
      ).run(['touch', '--plan'], stdout: out);

      expect(code, ExitCode.ok);
      expect(out.output, contains('No AI coding host found on this machine'));
    });

    test('--apply --autoapprove answers the same as --apply', () async {
      final bare = MemorySink();
      final auto = MemorySink();

      await _cliWith(
        _explaining('Already on the latest version'),
      ).run(['touch', '--apply'], stdout: bare);
      await _cliWith(
        _explaining('Already on the latest version'),
      ).run(['touch', '--apply', '--autoapprove'], stdout: auto);

      expect(auto.output, bare.output);
    });

    test('the reason reaches --json as the reason', () async {
      final out = MemorySink();
      await _cliWith(
        _explaining('Latest release is a prerelease — skipping.'),
      ).run(['touch', '--apply', '--json'], stdout: out);

      expect(
        out.output,
        contains('"reason": "Latest release is a prerelease — skipping."'),
      );
      // The plan carries it too, so a caller reading the plan alone sees it.
      expect(
        out.output,
        contains('"nothingToDo": "Latest release is a prerelease — skipping."'),
      );
      expect(out.output, contains('"applied": false'));
    });

    test('it is read after steps(), not before', () async {
      // A command works out that it has nothing to do *while* building its
      // steps — both real hosts assign the reason inside `steps()`. Asking
      // earlier would always read null.
      final command = _explaining('Already on the latest version');

      await _cliWith(command).run(['touch', '--apply'], stdout: MemorySink());

      expect(command.askedBeforeSteps, isFalse);
    });
  });

  group('a command with nothing to add', () {
    test('keeps the framework wording', () async {
      final out = MemorySink();
      await _cliWith(_explaining(null)).run(['touch', '--apply'], stdout: out);

      expect(out.output, contains('nothing would change'));
    });

    test('a command that does not implement the interface is unaffected',
        () async {
      // The interface is opt-in: a command that never heard of it must behave
      // exactly as before, which is what keeps this additive.
      final out = MemorySink();
      final code = await ModularCli()
          .command<TouchInput, TouchOutput>(
            'ping',
            (req) => PlainEmptyCommand(TouchInput()),
            description: 'Builds no steps, explains nothing',
          )
          .run(['ping', '--apply'], stdout: out);

      expect(code, ExitCode.ok);
      expect(out.output, contains('nothing would change'));
    });
  });

  group('an empty plan is not told to re-run', () {
    test('--plan does not invite an --apply that would do nothing', () async {
      final out = MemorySink();
      await _cliWith(_explaining(null)).run(['touch', '--plan'], stdout: out);

      expect(out.output, contains('--apply would do nothing either'));
      expect(out.output, isNot(contains('Re-run with --apply to carry')));
    });

    test('a plan with steps still says how to carry it out', () async {
      final out = MemorySink();
      await _cliWith(
        TouchCommand(TouchInput()),
      ).run(['touch', '--plan'], stdout: out);

      expect(out.output, contains('Re-run with --apply to carry this out'));
    });
  });
}
