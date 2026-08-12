/// A query reads and answers. It has nothing to preview, and the SDK refuses
/// to let it be asked for one.
library;

import 'package:modular_cli_sdk/modular_cli_sdk.dart';
import 'package:test/test.dart';

import 'doubles.dart';

void main() {
  group('a registered query', () {
    test('runs and writes its output', () async {
      final cli = ModularCli()
        ..query<CountInput, CountOutput>(
          'count',
          (req) => CountQuery(CountInput(3)),
          description: 'Count things',
          params: const [],
        );

      final out = MemorySink();
      final code = await cli.run(['count'], stdout: out);

      expect(code, ExitCode.ok);
      expect(out.output, contains('count: 3'));
    });

    test('rejects --plan, because it changes nothing to plan', () async {
      final cli = ModularCli()
        ..query<CountInput, CountOutput>(
          'count',
          (req) => CountQuery(CountInput(3)),
          params: const [],
        );

      final err = MemorySink();
      final code = await cli.run(['count', '--plan'], stderr: err);

      expect(code, ExitCode.validationFailed);
      expect(err.output, contains('--plan'));
    });

    test('rejects --apply for the same reason', () async {
      final cli = ModularCli()
        ..query<CountInput, CountOutput>(
          'count',
          (req) => CountQuery(CountInput(3)),
          params: const [],
        );

      final err = MemorySink();
      final code = await cli.run(['count', '--apply'], stderr: err);

      expect(code, ExitCode.validationFailed);
      expect(err.output, contains('--apply'));
    });

    test('still validates its input', () async {
      final cli = ModularCli()
        ..query<CountInput, CountOutput>(
          'count',
          (req) => CountQuery(CountInput(-1)),
          params: const [],
        );

      final err = MemorySink();
      final code = await cli.run(['count'], stderr: err);

      expect(code, ExitCode.validationFailed);
      expect(err.output, contains('cannot count backwards'));
    });

    test('can be registered inside a module', () async {
      final cli = ModularCli()
        ..module('things', (m) {
          m.query<CountInput, CountOutput>(
            'count',
            (req) => CountQuery(CountInput(7)),
            params: const [],
          );
        });

      final out = MemorySink();
      final code = await cli.run(['things', 'count'], stdout: out);

      expect(code, ExitCode.ok);
      expect(out.output, contains('count: 7'));
    });
  });

  group('the catalog', () {
    test('records a query as a query', () {
      final cli = ModularCli()
        ..query<CountInput, CountOutput>(
          'count',
          (req) => CountQuery(CountInput(3)),
        );

      expect(cli.catalog.forRoute('count')!.kind, CommandKind.query);
    });

    test('records a command as a command', () {
      final cli = ModularCli()
        ..command<TouchInput, TouchOutput>(
          'touch',
          (req) => TouchCommand(TouchInput()),
        );

      expect(cli.catalog.forRoute('touch')!.kind, CommandKind.command);
    });

    test('publishes the kind, so an agent can tell a reader from a writer', () {
      final cli = ModularCli()
        ..query<CountInput, CountOutput>(
          'count',
          (req) => CountQuery(CountInput(3)),
        );

      expect(cli.catalog.forRoute('count')!.toJson()['kind'], 'query');
    });

    test('gives help itself as a query, because help changes nothing',
        () async {
      final cli = ModularCli();
      await cli.run(['help'], stdout: MemorySink());

      expect(cli.catalog.forRoute('help')!.kind, CommandKind.query);
    });
  });
}
