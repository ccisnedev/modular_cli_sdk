/// A command is told which of the two it is doing, shows what it would do, and
/// is held to it.
library;

import 'dart:convert';

import 'package:modular_cli_sdk/modular_cli_sdk.dart';
import 'package:test/test.dart';

import 'doubles.dart';

void main() {
  group('a command invoked with neither flag', () {
    test('is refused, because neither is the default', () async {
      final cli = _cliWith(TouchCommand(TouchInput()));

      final err = MemorySink();
      final code = await cli.run(['touch'], stderr: err);

      expect(code, ExitCode.validationFailed);
      expect(err.output, contains('Choose --plan or --apply'));
    });

    test('does not build its steps first', () async {
      // The rules are applied before anything is computed, so a command that
      // would read the disk or reach a network does neither.
      final command = TouchCommand(TouchInput());
      final cli = _cliWith(command);

      await cli.run(['touch'], stderr: MemorySink());

      expect(command.built, isEmpty);
    });
  });

  group('a command invoked with both flags', () {
    test('is refused, because it says nothing about which was meant', () async {
      final cli = _cliWith(TouchCommand(TouchInput()));

      final err = MemorySink();
      final code = await cli.run(['touch', '--plan', '--apply'], stderr: err);

      expect(code, ExitCode.validationFailed);
      expect(err.output, contains('Choose one'));
    });
  });

  group('--autoapprove on its own', () {
    test('is refused, because it authorizes nothing', () async {
      final cli = _cliWith(TouchCommand(TouchInput()));

      final err = MemorySink();
      final code = await cli.run(['touch', '--autoapprove'], stderr: err);

      expect(code, ExitCode.validationFailed);
      expect(err.output, contains('authorizes nothing'));
    });
  });

  group('--plan', () {
    test('shows what would change', () async {
      final cli = _cliWith(
        TouchCommand(TouchInput(), targets: const ['a.txt', 'b.txt']),
      );

      final out = MemorySink();
      final code = await cli.run(['touch', '--plan'], stdout: out);

      expect(code, ExitCode.ok);
      expect(out.output, contains('create   a.txt'));
      expect(out.output, contains('create   b.txt'));
    });

    test('changes nothing', () async {
      final command = TouchCommand(TouchInput());
      final cli = _cliWith(command);

      await cli.run(['touch', '--plan'], stdout: MemorySink());

      expect(command.built.every((s) => !s.performed), isTrue);
    });

    test('never asks for approval', () async {
      var asked = false;
      final cli = _cliWith(
        TouchCommand(TouchInput()),
        approver: (_) async {
          asked = true;
          return true;
        },
      );

      await cli.run(['touch', '--plan'], stdout: MemorySink());

      expect(asked, isFalse);
    });

    test('files the plan where the host files it, and says where', () async {
      PlanDocument? filed;
      final cli = _cliWith(
        TouchCommand(TouchInput()),
        planSink: (plan) {
          filed = plan;
          return '/plans/touch.md';
        },
      );

      final out = MemorySink();
      await cli.run(['touch', '--plan'], stdout: out);

      expect(filed!.route, 'touch');
      expect(out.output, contains('/plans/touch.md'));
    });

    test('files it nowhere when the host files plans nowhere', () async {
      final cli = _cliWith(TouchCommand(TouchInput()));

      final out = MemorySink();
      await cli.run(['touch', '--plan'], stdout: out);

      expect(out.output, isNot(contains('written')));
    });

    test('answers --json with the steps as data, not as prose', () async {
      final cli = _cliWith(TouchCommand(TouchInput()));

      final out = MemorySink();
      await cli.run(['touch', '--plan', '--json'], stdout: out);

      final json = jsonDecode(out.output) as Map<String, dynamic>;
      expect(json['route'], 'touch');
      expect((json['steps'] as List).single, {
        'verb': 'create',
        'target': 'a.txt',
      });
    });
  });

  group('--apply', () {
    test('asks for approval, and carries the plan out when it is given',
        () async {
      String? shown;
      final command = TouchCommand(TouchInput());
      final cli = _cliWith(
        command,
        approver: (plan) async {
          shown = plan;
          return true;
        },
      );

      final out = MemorySink();
      final code = await cli.run(['touch', '--apply'], stdout: out);

      expect(shown, contains('create   a.txt'));
      expect(command.built.single.performed, isTrue);
      expect(code, ExitCode.ok);
      expect(out.output, contains('touched: a.txt'));
    });

    test('changes nothing when approval is refused', () async {
      final command = TouchCommand(TouchInput());
      final cli = _cliWith(command, approver: (_) async => false);

      final out = MemorySink();
      final code = await cli.run(['touch', '--apply'], stdout: out);

      expect(command.built.single.performed, isFalse);
      expect(code, ExitCode.genericError);
      expect(out.output, contains('Nothing was changed'));
    });

    test('refuses rather than hanging when there is nobody to ask', () async {
      final command = TouchCommand(TouchInput());
      final cli = _cliWith(
        command,
        approver: (_) async => throw const NoApproverAvailable(),
      );

      final out = MemorySink();
      final code = await cli.run(['touch', '--apply'], stdout: out);

      expect(command.built.single.performed, isFalse);
      expect(code, ExitCode.genericError);
      expect(out.output, contains('--autoapprove'));
    });

    test('with --autoapprove does not ask at all', () async {
      var asked = false;
      final command = TouchCommand(TouchInput());
      final cli = _cliWith(
        command,
        approver: (_) async {
          asked = true;
          return true;
        },
      );

      final code = await cli.run([
        'touch',
        '--apply',
        '--autoapprove',
      ], stdout: MemorySink());

      expect(asked, isFalse);
      expect(command.built.single.performed, isTrue);
      expect(code, ExitCode.ok);
    });
  });

  group('a run that broke its word', () {
    test('says so on stderr, whatever the command chose to report', () async {
      final cli = _cliWith(_MisreportingCommand());

      final out = MemorySink();
      final err = MemorySink();
      final code = await cli.run(
        ['misreport', '--apply', '--autoapprove'],
        stdout: out,
        stderr: err,
      );

      expect(err.output, contains('said it would "create a.txt"'));
      expect(err.output, contains('reported "keep a.txt"'));
      // The work reached its end, so the command's own answer stands.
      expect(code, ExitCode.ok);
      expect(out.output, contains('touched: a.txt'));
    });
  });

  group('a run that stopped halfway', () {
    test('reports where it stopped and fails the invocation', () async {
      final cli = _cliWith(
        TouchCommand(
          TouchInput(),
          targets: const ['a.txt', 'b.txt'],
          error: StateError('the disk went away'),
        ),
      );

      final out = MemorySink();
      final err = MemorySink();
      final code = await cli.run(
        ['touch', '--apply', '--autoapprove'],
        stdout: out,
        stderr: err,
      );

      expect(err.output, contains('the disk went away'));
      expect(code, ExitCode.genericError);
    });

    test('still lets the command report what it managed', () async {
      final cli = _cliWith(
        TouchCommand(
          TouchInput(),
          targets: const ['a.txt'],
          error: StateError('the disk went away'),
        ),
      );

      final out = MemorySink();
      await cli.run(
        ['touch', '--apply', '--autoapprove'],
        stdout: out,
        stderr: MemorySink(),
      );

      expect(out.output, contains('touched:'));
    });
  });

  group("a command's declared parameters", () {
    test('are joined by the three flags, not replaced by them', () async {
      final cli = _cliWith(
        TouchCommand(TouchInput()),
        params: [CliParam.string('name', description: 'Who')],
      );

      final contract = cli.catalog.forRoute('touch')!;
      final names = contract.declaredParams.map((p) => p.name);

      expect(names, containsAll(['name', 'plan', 'apply', 'autoapprove']));
    });

    test('appear in its help', () async {
      final cli = _cliWith(TouchCommand(TouchInput()));

      final out = MemorySink();
      await cli.run(['touch', '--help'], stdout: out);

      expect(out.output, contains('--plan'));
      expect(out.output, contains('--apply'));
      expect(out.output, contains('--autoapprove'));
    });
  });
}

// ── Helpers ─────────────────────────────────────────────────────────────────

ModularCli _cliWith(
  Command<dynamic, dynamic> command, {
  Approver? approver,
  PlanSink? planSink,
  List<CliParam>? params,
}) {
  final cli = ModularCli(approver: approver, planSink: planSink);
  if (command is TouchCommand) {
    cli.command<TouchInput, TouchOutput>(
      'touch',
      (req) => command,
      description: 'Touch things',
      params: params,
    );
  } else {
    cli.command<TouchInput, TouchOutput>(
      'misreport',
      (req) => command as _MisreportingCommand,
      params: params,
    );
  }
  return cli;
}

/// A command whose step announces `create` and reports `keep`.
class _MisreportingCommand implements Command<TouchInput, TouchOutput> {
  @override
  final TouchInput input = TouchInput();

  final List<FakeStep> built = [];

  @override
  String? validate() => null;

  @override
  Future<List<Step>> steps() async {
    built
      ..clear()
      ..add(FakeStep(verb: 'create', target: 'a.txt', reportedVerb: 'keep'));
    return built;
  }

  @override
  TouchOutput describe(Execution execution) =>
      TouchOutput(execution.outcomes.map((o) => o.target).toList());
}
