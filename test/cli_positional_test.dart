import 'package:modular_cli_sdk/modular_cli_sdk.dart';
import 'package:test/test.dart';

void main() {
  group('CliPositional.string', () {
    test('parses any string when no allow-list is declared', () {
      final id = CliPositional.string('id', required: true);
      expect(id.parse('anything'), 'anything');
    });

    test('accepts a value from its declared allow-list', () {
      final mode = CliPositional.string(
        'mode',
        required: true,
        values: const ['read', 'write'],
      );
      expect(mode.parse('read'), 'read');
    });

    test('rejects a value outside its declared allow-list', () {
      final mode = CliPositional.string(
        'mode',
        required: true,
        values: const ['read', 'write'],
      );
      expect(
        () => mode.parse('delete'),
        throwsA(
          isA<CommandException>()
              .having((e) => e.code, 'code', 'VALIDATION_FAILED')
              .having((e) => e.exitCode, 'exitCode', ExitCode.validationFailed)
              .having(
                (e) => e.details,
                'details',
                containsPair('parameter', 'mode'),
              ),
        ),
      );
    });

    test('an empty allow-list is a declaration error, not a runtime one', () {
      expect(
        () => CliPositional.string('mode', required: true, values: const []),
        throwsArgumentError,
      );
    });
  });

  group('CliPositional.integer', () {
    final port = CliPositional.integer('port', required: true);

    test('coerces a well-formed integer', () {
      expect(port.parse('8080'), 8080);
    });

    test('rejects text that does not parse as an integer', () {
      expect(
        () => port.parse('abc'),
        throwsA(
          isA<CommandException>().having(
            (e) => e.message,
            'message',
            contains('an integer'),
          ),
        ),
      );
    });

    test('rejects a decimal, since it is not an integer', () {
      expect(() => port.parse('3.5'), throwsA(isA<CommandException>()));
    });
  });

  group('CliPositional.number', () {
    final scale = CliPositional.number('scale', required: true);

    test('coerces an integer-looking value too', () {
      expect(scale.parse('2'), 2.0);
    });

    test('coerces a decimal value', () {
      expect(scale.parse('1.5'), 1.5);
    });

    test('rejects text that is not a number', () {
      expect(() => scale.parse('nope'), throwsA(isA<CommandException>()));
    });
  });

  group('toJson', () {
    test('carries name, kind, type, required and description', () {
      final id = CliPositional.integer(
        'id',
        required: true,
        description: 'Record id',
      );
      expect(id.toJson(), {
        'name': 'id',
        'kind': 'positional',
        'type': 'integer',
        'required': true,
        'description': 'Record id',
      });
    });

    test('carries the allow-list when one was declared', () {
      final mode = CliPositional.string(
        'mode',
        required: true,
        values: const ['read', 'write'],
      );
      expect(mode.toJson()['allowed'], ['read', 'write']);
    });

    test('omits "allowed" and "description" when neither was declared', () {
      final id = CliPositional.integer('id', required: true);
      expect(id.toJson().containsKey('allowed'), isFalse);
      expect(id.toJson().containsKey('description'), isFalse);
    });

    test('carries required: false for an optional positional', () {
      final program = CliPositional.string('program', required: false);
      expect(program.toJson()['required'], isFalse);
    });
  });
}
