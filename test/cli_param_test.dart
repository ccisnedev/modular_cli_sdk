import 'package:modular_cli_sdk/modular_cli_sdk.dart';
import 'package:test/test.dart';

void main() {
  group('CliParam kinds', () {
    test('an option carries a value', () {
      final param = CliParam.integer('count', description: 'How many');

      expect(param.kind, equals(CliParamKind.option));
      expect(param.type, equals(CliParamType.integer));
      expect(param.name, equals('count'));
      expect(param.description, equals('How many'));
    });

    test('a boolean flag needs no value', () {
      final param = CliParam.boolean('verbose', abbr: 'v');

      expect(param.kind, equals(CliParamKind.flag));
      expect(param.type, equals(CliParamType.boolean));
      expect(param.abbr, equals('v'));
    });

    test('a positional is required and has no abbr', () {
      final param = CliParam.positional('id', description: 'Record id');

      expect(param.kind, equals(CliParamKind.positional));
      expect(param.required, isTrue);
      expect(param.abbr, isNull);
    });
  });

  group('CliParam facets', () {
    test('required and default are mutually exclusive', () {
      expect(
        () => CliParam.string('name', required: true, defaultValue: 'World'),
        throwsArgumentError,
      );
    });

    test('an optional param may declare a default', () {
      final param = CliParam.string('name', defaultValue: 'World');

      expect(param.required, isFalse);
      expect(param.defaultValue, equals('World'));
    });

    test('a param may restrict its accepted values', () {
      final param = CliParam.string('format', allowed: ['text', 'json']);

      expect(param.allowed, equals(['text', 'json']));
    });

    test('aliases list the long name and the abbr', () {
      expect(CliParam.integer('a', abbr: 'a').aliases, equals(['a']));
      expect(CliParam.integer('count').aliases, isEmpty);
    });
  });

  group('CliParam.toJson — the shape help --json emits', () {
    test('describes an option fully', () {
      final json = CliParam.integer(
        'count',
        abbr: 'c',
        required: true,
        description: 'How many',
      ).toJson();

      expect(json, {
        'name': 'count',
        'kind': 'option',
        'type': 'integer',
        'aliases': ['c'],
        'required': true,
        'description': 'How many',
      });
    });

    test('omits absent facets and includes the declared ones', () {
      final json = CliParam.string(
        'format',
        defaultValue: 'text',
        allowed: ['text', 'json'],
      ).toJson();

      expect(json['default'], equals('text'));
      expect(json['allowed'], equals(['text', 'json']));
      expect(json.containsKey('description'), isFalse);
    });
  });

  group('CliParam parsing of a raw argument value', () {
    test('coerces to the declared type', () {
      expect(CliParam.integer('a').parse('42'), equals(42));
      expect(CliParam.number('r').parse('1.5'), equals(1.5));
      expect(CliParam.string('n').parse('World'), equals('World'));
      expect(CliParam.boolean('v').parse('true'), isTrue);
      expect(CliParam.boolean('v').parse(''), isTrue);
    });

    test('reports a value it cannot coerce', () {
      expect(
        () => CliParam.integer('a').parse('abc'),
        throwsA(isA<CommandException>()),
      );
    });

    test('reports a value outside the allowed set', () {
      expect(
        () => CliParam.string('format', allowed: ['text', 'json']).parse('xml'),
        throwsA(isA<CommandException>()),
      );
    });
  });
}
