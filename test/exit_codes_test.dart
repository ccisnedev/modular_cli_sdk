import 'package:modular_cli_sdk/modular_cli_sdk.dart';
import 'package:test/test.dart';

void main() {
  group('ExitCode', () {
    test('should define OK as 0', () {
      expect(ExitCode.ok, 0);
    });

    test('should cover all documented exit codes', () {
      expect(ExitCode.ok, 0);
      expect(ExitCode.genericError, 1);
      expect(ExitCode.apiError, 2);
      expect(ExitCode.notFound, 4);
      expect(ExitCode.unauthorized, 5);
      expect(ExitCode.conflict, 6);
      expect(ExitCode.validationFailed, 7);
      expect(ExitCode.invalidUsage, 64);
    });

    test('should define distinct codes for each error category', () {
      expect(ExitCode.all.length, 8, reason: 'all codes must be unique');
    });
  });
}
