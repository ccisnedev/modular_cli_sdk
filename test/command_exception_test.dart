import 'package:modular_cli_sdk/modular_cli_sdk.dart';
import 'package:test/test.dart';

void main() {
  group('CommandException', () {
    test('stores id, message, exitCode and details', () {
      final error = CommandException(
        id: 'not-found',
        message: 'Resource not found',
        exitCode: ExitCode.notFound,
        details: {'id': '42'},
      );

      expect(error.id, 'not-found');
      expect(error.message, 'Resource not found');
      expect(error.exitCode, ExitCode.notFound);
      expect(error.details, {'id': '42'});
    });

    test('exitCode is required, with no default', () {
      final error = CommandException(
        id: 'fail',
        message: 'Something broke',
        exitCode: ExitCode.genericError,
      );

      expect(error.exitCode, ExitCode.genericError);
    });

    test('carries no isRetryable field at all', () {
      final error = CommandException(
        id: 'conflict',
        message: 'State conflict',
        exitCode: ExitCode.conflict,
        details: {'current': 'open', 'requested': 'closed'},
      );

      final json = error.toJson();
      expect(json.containsKey('isRetryable'), isFalse);
    });

    group('id must be kebab-case', () {
      test('accepts lowercase words separated by single hyphens', () {
        expect(
          () => CommandException(
            id: 'ticket-not-found',
            message: 'm',
            exitCode: ExitCode.notFound,
          ),
          returnsNormally,
        );
      });

      test('accepts a single lowercase word', () {
        expect(
          () => CommandException(id: 'conflict', message: 'm', exitCode: 1),
          returnsNormally,
        );
      });

      test('rejects SCREAMING_SNAKE_CASE', () {
        expect(
          () => CommandException(
            id: 'NOT_FOUND',
            message: 'm',
            exitCode: ExitCode.notFound,
          ),
          throwsArgumentError,
        );
      });

      test('rejects camelCase', () {
        expect(
          () => CommandException(id: 'notFound', message: 'm', exitCode: 1),
          throwsArgumentError,
        );
      });

      test('rejects uppercase letters', () {
        expect(
          () => CommandException(id: 'Not-Found', message: 'm', exitCode: 1),
          throwsArgumentError,
        );
      });

      test('rejects a leading or trailing hyphen', () {
        expect(
          () => CommandException(id: '-not-found', message: 'm', exitCode: 1),
          throwsArgumentError,
        );
        expect(
          () => CommandException(id: 'not-found-', message: 'm', exitCode: 1),
          throwsArgumentError,
        );
      });

      test('rejects a doubled hyphen', () {
        expect(
          () => CommandException(id: 'not--found', message: 'm', exitCode: 1),
          throwsArgumentError,
        );
      });

      test('rejects an empty id', () {
        expect(
          () => CommandException(id: '', message: 'm', exitCode: 1),
          throwsArgumentError,
        );
      });
    });

    test('toJson serializes id, message, exitCode; omits null details', () {
      final error = CommandException(
        id: 'generic',
        message: 'Oops',
        exitCode: ExitCode.genericError,
      );

      final json = error.toJson();
      expect(json, {
        'id': 'generic',
        'message': 'Oops',
        'exitCode': ExitCode.genericError,
      });
      expect(json.containsKey('details'), isFalse);
    });

    test('toJson includes details when set', () {
      final error = CommandException(
        id: 'unauthorized',
        message: 'Bad token',
        exitCode: ExitCode.unauthorized,
        details: {'token': 'abc123', 'position': 4},
      );

      final json = error.toJson();
      expect(json['details'], {'token': 'abc123', 'position': 4});
    });

    test('implements the Exception interface', () {
      final error = CommandException(id: 'e', message: 'm', exitCode: 1);
      expect(error, isA<Exception>());
    });
  });
}
