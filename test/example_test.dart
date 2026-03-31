import 'package:test/test.dart';

import '../example/example.dart' show runExample;

void main() {
  group('Example', () {
    test('should run version and return exit code 0', () async {
      final code = await runExample(['version']);
      expect(code, 0);
    });

    test('should run greetings hello and return exit code 0', () async {
      final code = await runExample(['greetings', 'hello', '--name', 'World']);
      expect(code, 0);
    });

    test('should run math add and return exit code 0', () async {
      final code = await runExample(['math', 'add', '--a', '5', '--b', '3']);
      expect(code, 0);
    });

    test('should return exit code 64 for unknown command', () async {
      final code = await runExample(['unknown', 'command']);
      expect(code, 64);
    });
  });
}
