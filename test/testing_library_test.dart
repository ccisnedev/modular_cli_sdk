/// The testing library drives a command exactly as the framework does.
///
/// That "exactly" is the whole point, and it is what the last group here pins:
/// a helper that merely *resembles* `ModuleBuilder` is a second description of
/// the same lifecycle with nothing keeping the two in agreement — which is the
/// failure this package exists to prevent, reintroduced in the test suite.
library;

import 'dart:convert';

import 'package:modular_cli_sdk/modular_cli_sdk.dart';
import 'package:modular_cli_sdk/testing.dart';
import 'package:test/test.dart';

import 'doubles.dart';

void main() {
  group('previewCommand', () {
    test('returns what the steps say they would do', () async {
      final previews = await previewCommand(
        TouchCommand(TouchInput(), targets: const ['a.txt', 'b.txt']),
      );

      expect(previews.map((p) => p.verb), ['create', 'create']);
      expect(previews.map((p) => p.target), ['a.txt', 'b.txt']);
    });

    test('performs nothing', () async {
      final command = TouchCommand(TouchInput());

      await previewCommand(command);

      expect(command.built.single.performed, isFalse);
    });
  });

  group('runCommand', () {
    test('performs the steps and reports the run', () async {
      final command = TouchCommand(TouchInput());

      final execution = await runCommand(command);

      expect(command.built.single.performed, isTrue);
      expect(execution.isFaithful, isTrue);
      expect(execution.isComplete, isTrue);
    });

    test('reports a step that did other than it said', () async {
      final execution = await runCommand(_Misreporting());

      expect(execution.isFaithful, isFalse);
      expect(execution.discrepancies.single.actedDifferently, isTrue);
    });

    test('reports a step that threw, without letting it escape', () async {
      final execution = await runCommand(
        TouchCommand(TouchInput(), error: StateError('the disk went away')),
      );

      expect(execution.isComplete, isFalse);
      expect(execution.failure!.message, contains('the disk went away'));
    });
  });

  group('applyCommand', () {
    test("returns the command's own Output, at its own type", () async {
      // Typed, not widened to Output: a test that has to cast before it can
      // assert anything is a test the helper made worse.
      final TouchOutput output = await applyCommand(
        TouchCommand(TouchInput(), targets: const ['a.txt', 'b.txt']),
      );

      expect(output.touched, ['a.txt', 'b.txt']);
    });

    test('describes what happened even when the run stopped halfway', () async {
      final output = await applyCommand(
        TouchCommand(
          TouchInput(),
          targets: const ['a.txt'],
          error: StateError('nope'),
        ),
      );

      expect(output.touched, isEmpty);
    });
  });

  group('it agrees with the framework', () {
    test('applyCommand produces what --apply --autoapprove produces', () async {
      final throughHelper = await applyCommand(
        TouchCommand(TouchInput(), targets: const ['a.txt', 'b.txt']),
      );

      final out = MemorySink();
      await (ModularCli()..command<TouchInput, TouchOutput>(
        'touch',
        (req) => TouchCommand(TouchInput(), targets: const ['a.txt', 'b.txt']),
      )).run(['touch', '--apply', '--autoapprove', '--json'], stdout: out);

      expect(jsonDecode(out.output), throughHelper.toJson());
    });

    test('previewCommand produces what --plan lists', () async {
      final throughHelper = await previewCommand(
        TouchCommand(TouchInput(), targets: const ['a.txt', 'b.txt']),
      );

      final out = MemorySink();
      await (ModularCli()..command<TouchInput, TouchOutput>(
        'touch',
        (req) => TouchCommand(TouchInput(), targets: const ['a.txt', 'b.txt']),
      )).run(['touch', '--plan', '--json'], stdout: out);

      final steps =
          (jsonDecode(out.output) as Map<String, dynamic>)['steps'] as List;

      expect(steps, throughHelper.map((p) => p.toJson()).toList());
    });
  });
}

class _Misreporting implements Command<TouchInput, TouchOutput> {
  @override
  final TouchInput input = TouchInput();

  @override
  String? validate() => null;

  @override
  Future<List<Step>> steps() async => [
    FakeStep(verb: 'create', target: 'a.txt', reportedVerb: 'keep'),
  ];

  @override
  TouchOutput describe(Execution execution) =>
      TouchOutput(execution.outcomes.map((o) => o.target).toList());
}
