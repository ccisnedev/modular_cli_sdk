import 'package:modular_cli_sdk/modular_cli_sdk.dart';
import 'package:test/test.dart';

void main() {
  group('CommandException', () {
    test('should store code, message, and details', () {
      final error = CommandException(
        code: 'NOT_FOUND',
        message: 'Resource not found',
        exitCode: ExitCode.notFound,
        details: {'id': '42'},
      );

      expect(error.code, 'NOT_FOUND');
      expect(error.message, 'Resource not found');
      expect(error.exitCode, ExitCode.notFound);
      expect(error.details, {'id': '42'});
    });

    test('should default isRetryable to false', () {
      final error = CommandException(code: 'FAIL', message: 'Something broke');

      expect(error.isRetryable, isFalse);
    });

    test('should serialize to JSON with all fields', () {
      final error = CommandException(
        code: 'CONFLICT',
        message: 'State conflict',
        exitCode: ExitCode.conflict,
        isRetryable: true,
        details: {'current': 'open', 'requested': 'closed'},
      );

      final json = error.toJson();
      expect(json['error'], 'CONFLICT');
      expect(json['message'], 'State conflict');
      expect(json['exitCode'], ExitCode.conflict);
      expect(json['isRetryable'], true);
      expect(json['details'], {'current': 'open', 'requested': 'closed'});
    });

    test('should serialize to JSON omitting null details', () {
      final error = CommandException(code: 'GENERIC', message: 'Oops');

      final json = error.toJson();
      expect(json.containsKey('details'), isFalse);
    });

    test('should map error code to correct exit code', () {
      final error = CommandException(
        code: 'UNAUTHORIZED',
        message: 'Bad token',
        exitCode: ExitCode.unauthorized,
      );

      expect(error.exitCode, 5);
    });

    test('should implement Exception interface', () {
      final error = CommandException(code: 'E', message: 'm');
      expect(error, isA<Exception>());
    });
  });
}
