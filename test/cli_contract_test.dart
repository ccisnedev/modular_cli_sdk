import 'package:modular_cli_sdk/modular_cli_sdk.dart';
import 'package:test/test.dart';

void main() {
  group('ExactlyOne', () {
    const constraint = ExactlyOne(['plan', 'apply']);

    test('is satisfied when exactly one field is present', () {
      expect(constraint.check({'plan'}), isNull);
      expect(constraint.check({'apply'}), isNull);
    });

    test('is violated when none of the fields are present', () {
      expect(constraint.check(const {}), contains('Choose one of'));
    });

    test('is violated when more than one field is present', () {
      final violation = constraint.check({'plan', 'apply'});
      expect(violation, contains('Choose one of'));
      expect(violation, contains('--plan'));
      expect(violation, contains('--apply'));
    });

    test('is indifferent to fields outside its own list', () {
      expect(constraint.check({'plan', 'json'}), isNull);
    });

    test('serializes its kind and fields', () {
      expect(constraint.toJson(), {
        'kind': 'exactlyOne',
        'fields': ['plan', 'apply'],
      });
    });
  });

  group('MutuallyExclusive', () {
    const constraint = MutuallyExclusive(['quiet', 'verbose']);

    test('is satisfied when neither field is present', () {
      expect(constraint.check(const {}), isNull);
    });

    test('is satisfied when exactly one field is present', () {
      expect(constraint.check({'quiet'}), isNull);
    });

    test('is violated when both fields are present', () {
      final violation = constraint.check({'quiet', 'verbose'});
      expect(violation, contains('cannot be combined'));
      expect(violation, contains('--quiet'));
      expect(violation, contains('--verbose'));
    });

    test('serializes its kind and fields', () {
      expect(constraint.toJson(), {
        'kind': 'mutuallyExclusive',
        'fields': ['quiet', 'verbose'],
      });
    });
  });

  group('CliContract', () {
    test('CliContract.none declares nothing', () {
      expect(CliContract.none.options, isEmpty);
      expect(CliContract.none.positionals, isEmpty);
      expect(CliContract.none.constraints, isEmpty);
    });

    test('withOptions appends without mutating the original', () {
      final base = CliContract(
        options: [CliParam.flag('verbose', abbr: 'v', repeatable: false)],
      );
      final extended = base.withOptions([
        CliParam.flag('plan', abbr: null, repeatable: false),
      ]);

      expect(base.options, hasLength(1));
      expect(extended.options, hasLength(2));
      expect(extended.options.map((o) => o.name), ['verbose', 'plan']);
    });

    test(
      'toOptionSpecs mirrors the declared options as router OptionSpecs',
      () {
        final contract = CliContract(
          options: [
            CliParam.string(
              'name',
              abbr: 'n',
              required: true,
              repeatable: false,
              defaultValue: null,
            ),
          ],
        );

        final specs = contract.toOptionSpecs();
        expect(specs, hasLength(1));
        expect(specs.single.name, 'name');
        expect(specs.single.required, isTrue);
      },
    );

    test(
      'validateConstraints passes silently when every rule is satisfied',
      () {
        final contract = CliContract(
          options: [
            CliParam.flag('plan', abbr: null, repeatable: false),
            CliParam.flag('apply', abbr: null, repeatable: false),
          ],
          constraints: const [
            ExactlyOne(['plan', 'apply']),
          ],
        );

        expect(() => contract.validateConstraints({'plan'}), returnsNormally);
      },
    );

    test('validateConstraints throws on the first violated rule', () {
      final contract = CliContract(
        options: [
          CliParam.flag('plan', abbr: null, repeatable: false),
          CliParam.flag('apply', abbr: null, repeatable: false),
        ],
        constraints: const [
          ExactlyOne(['plan', 'apply']),
        ],
      );

      expect(
        () => contract.validateConstraints(const {}),
        throwsA(
          isA<CommandException>()
              .having((e) => e.id, 'id', 'validation-failed')
              .having((e) => e.exitCode, 'exitCode', ExitCode.validationFailed),
        ),
      );
    });

    test('toJson carries options, positionals and constraints', () {
      final contract = CliContract(
        options: [CliParam.flag('plan', abbr: null, repeatable: false)],
        positionals: [CliPositional.string('name', required: true)],
        constraints: const [
          MutuallyExclusive(['plan', 'apply']),
        ],
      );

      final json = contract.toJson();
      expect(json['options'], hasLength(1));
      expect(json['positionals'], hasLength(1));
      expect(json['constraints'], [
        {
          'kind': 'mutuallyExclusive',
          'fields': ['plan', 'apply'],
        },
      ]);
    });
  });
}
