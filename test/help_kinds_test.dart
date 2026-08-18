/// Help tells a reader which routes read and which ones change.
///
/// It is the question a person asks before running an unfamiliar CLI, and until
/// now the listing could not answer it.
library;

import 'dart:convert';

import 'package:modular_cli_sdk/modular_cli_sdk.dart';
import 'package:test/test.dart';

import 'doubles.dart';

void main() {
  group('a CLI with both kinds', () {
    late String listing;

    setUp(() async {
      final cli = ModularCli()
        ..query<CountInput, CountOutput>(
          'count',
          (req) => CountQuery(CountInput(3)),
          description: 'Count things',
        )
        ..command<TouchInput, TouchOutput>(
          'touch',
          (req) => TouchCommand(TouchInput()),
          description: 'Touch things',
        );

      final out = MemorySink();
      await cli.run(['help'], stdout: out);
      listing = out.output;
    });

    test('lists what reads apart from what changes', () {
      expect(listing, contains('Queries:'));
      expect(listing, contains('Commands:'));
    });

    test('puts each route under its own heading', () {
      final queries = listing.indexOf('Queries:');
      final commands = listing.indexOf('Commands:');

      expect(listing.indexOf('count'), greaterThan(queries));
      expect(listing.indexOf('count'), lessThan(commands));
      expect(listing.indexOf('touch'), greaterThan(commands));
    });

    test('counts help itself among the queries', () {
      final queries = listing.indexOf('Queries:');
      final commands = listing.indexOf('Commands:');

      expect(listing.indexOf('help'), greaterThan(queries));
      expect(listing.indexOf('help'), lessThan(commands));
    });
  });

  group('a CLI of one kind', () {
    test(
      'keeps a single listing, because there is nothing to tell apart',
      () async {
        // Two headings over one list would be noise, and every CLI written before
        // commands existed is this shape.
        final cli = ModularCli()
          ..query<CountInput, CountOutput>(
            'count',
            (req) => CountQuery(CountInput(3)),
            description: 'Count things',
          );

        final out = MemorySink();
        await cli.run(['help'], stdout: out);

        expect(out.output, contains('Commands:'));
        expect(out.output, isNot(contains('Queries:')));
      },
    );
  });

  group('help --json', () {
    test('carries the kind of every route', () async {
      final cli = ModularCli()
        ..query<CountInput, CountOutput>(
          'count',
          (req) => CountQuery(CountInput(3)),
        )
        ..command<TouchInput, TouchOutput>(
          'touch',
          (req) => TouchCommand(TouchInput()),
        );

      final out = MemorySink();
      await cli.run(['help', '--json'], stdout: out);

      final commands =
          (jsonDecode(out.output) as Map<String, dynamic>)['commands'] as List;
      final kinds = {
        for (final c in commands.cast<Map<String, dynamic>>())
          c['route']: c['kind'],
      };

      expect(kinds['count'], 'query');
      expect(kinds['touch'], 'command');
      expect(kinds['help'], 'query');
    });
  });
}
