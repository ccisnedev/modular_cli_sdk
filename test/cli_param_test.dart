import 'package:modular_cli_sdk/modular_cli_sdk.dart';
import 'package:test/test.dart';

void main() {
  group('CliParam factories — options only', () {
    test('an integer option carries its declared facets', () {
      final param = CliParam.integer(
        'count',
        required: false,
        repeatable: false,
        description: 'How many',
      );

      expect(param.type, equals(CliParamType.integer));
      expect(param.name, equals('count'));
      expect(param.description, equals('How many'));
      expect(param.isFlag, isFalse);
    });

    test('a flag needs no value and is never required', () {
      final param = CliParam.flag('verbose', abbr: 'v', repeatable: false);

      expect(param.type, equals(CliParamType.flag));
      expect(param.isFlag, isTrue);
      expect(param.abbr, equals('v'));
      expect(param.required, isFalse);
    });

    test('an enumeration must declare its values', () {
      expect(
        () => CliParam.enumeration(
          'format',
          required: false,
          repeatable: false,
          values: const [],
        ),
        throwsArgumentError,
      );
    });

    test('a path may require the target to exist', () {
      final param = CliParam.path(
        'config',
        required: false,
        repeatable: false,
        mustExist: true,
      );

      expect(param.mustExist, isTrue);
    });
  });

  group('CliParam facets', () {
    test('required and a default are mutually exclusive', () {
      expect(
        () => CliParam.string(
          'name',
          required: true,
          repeatable: false,
          defaultValue: const DeclaredDefault('World', reason: 'fallback'),
        ),
        throwsArgumentError,
      );
    });

    test('an optional param may declare a default with its reason', () {
      final param = CliParam.string(
        'name',
        required: false,
        repeatable: false,
        defaultValue: const DeclaredDefault(
          'World',
          reason: 'the name used when nobody gave one',
        ),
      );

      expect(param.required, isFalse);
      expect(param.defaultValue!.value, equals('World'));
      expect(
        param.defaultValue!.reason,
        equals('the name used when nobody gave one'),
      );
    });

    test('an enumeration restricts its accepted values', () {
      final param = CliParam.enumeration(
        'format',
        required: false,
        repeatable: false,
        values: const ['text', 'json'],
      );

      expect(param.values, equals(['text', 'json']));
    });

    test('aliases list the abbr, or nothing when there is none', () {
      expect(
        CliParam.integer(
          'a',
          abbr: 'a',
          required: false,
          repeatable: false,
        ).aliases,
        equals(['a']),
      );
      expect(
        CliParam.integer('count', required: false, repeatable: false).aliases,
        isEmpty,
      );
    });
  });

  group('CliParam.toJson — the shape help --json emits', () {
    test('describes an option fully', () {
      final json = CliParam.integer(
        'count',
        abbr: 'c',
        required: true,
        repeatable: false,
        description: 'How many',
      ).toJson();

      expect(json, {
        'name': 'count',
        'kind': 'option',
        'type': 'integer',
        'aliases': ['c'],
        'required': true,
        'repeatable': false,
        'description': 'How many',
      });
    });

    test('omits absent facets and includes the declared ones', () {
      final json = CliParam.enumeration(
        'format',
        required: false,
        repeatable: false,
        defaultValue: const DeclaredDefault('text', reason: 'plain by default'),
        values: const ['text', 'json'],
      ).toJson();

      expect(json['default'], equals('text'));
      expect(json['defaultReason'], equals('plain by default'));
      expect(json['allowed'], equals(['text', 'json']));
      expect(json.containsKey('description'), isFalse);
    });
  });

  group('CliParam parsing of a raw argument value', () {
    test('coerces to the declared type', () {
      expect(
        CliParam.integer('a', required: false, repeatable: false).parse('42'),
        equals(42),
      );
      expect(
        CliParam.number('r', required: false, repeatable: false).parse('1.5'),
        equals(1.5),
      );
      expect(
        CliParam.string('n', required: false, repeatable: false).parse('World'),
        equals('World'),
      );
      expect(CliParam.flag('v', repeatable: false).parse(''), isTrue);
    });

    test('reports a value it cannot coerce', () {
      expect(
        () => CliParam.integer(
          'a',
          required: false,
          repeatable: false,
        ).parse('abc'),
        throwsA(isA<CommandException>()),
      );
    });

    test('reports a value outside the allowed set', () {
      expect(
        () => CliParam.enumeration(
          'format',
          required: false,
          repeatable: false,
          values: const ['text', 'json'],
        ).parse('xml'),
        throwsA(isA<CommandException>()),
      );
    });

    test('reports a path that must exist but does not', () {
      expect(
        () => CliParam.path(
          'config',
          required: false,
          repeatable: false,
          mustExist: true,
        ).parse('/no/such/file/anywhere.yaml'),
        throwsA(isA<CommandException>()),
      );
    });

    test('accepts a path that must exist and does', () {
      final param = CliParam.path(
        'config',
        required: false,
        repeatable: false,
        mustExist: true,
      );
      // The package's own pubspec.yaml always exists at the working directory
      // this suite runs from.
      expect(param.parse('pubspec.yaml'), equals('pubspec.yaml'));
    });
  });
}
