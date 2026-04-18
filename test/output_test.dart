import 'package:modular_cli_sdk/modular_cli_sdk.dart';
import 'package:test/test.dart';

/// Concrete Output for testing.
class _TestOutput extends Output {
  final String greeting;
  _TestOutput({required this.greeting});

  @override
  Map<String, dynamic> toJson() => {'greeting': greeting};

  @override
  int get exitCode => ExitCode.ok;
}

/// Output with custom toText() override.
class _CustomTextOutput extends Output {
  final String diagram;
  _CustomTextOutput({required this.diagram});

  @override
  Map<String, dynamic> toJson() => {'diagram': diagram};

  @override
  int get exitCode => ExitCode.ok;

  @override
  String? toText() => diagram;
}

void main() {
  group('Output', () {
    test('should require toJson() and exitCode implementations', () {
      final output = _TestOutput(greeting: 'Hello');
      expect(output.toJson(), isA<Map<String, dynamic>>());
      expect(output.exitCode, isA<int>());
    });

    test('should allow optional schemaFields (defaults to null)', () {
      final output = _TestOutput(greeting: 'Hello');
      expect(output.schemaFields, isNull);
    });

    test('concrete Output should serialize correctly', () {
      final output = _TestOutput(greeting: 'Hello, World!');
      expect(output.toJson(), {'greeting': 'Hello, World!'});
      expect(output.exitCode, 0);
    });

    test('default toText() returns null', () {
      final output = _TestOutput(greeting: 'Hello');
      expect(output.toText(), isNull);
    });

    test('toText() can be overridden to return custom text', () {
      final output = _CustomTextOutput(diagram: 'MY DIAGRAM');
      expect(output.toText(), equals('MY DIAGRAM'));
    });

    test('toText() override does not affect toJson()', () {
      final output = _CustomTextOutput(diagram: 'MY DIAGRAM');
      expect(output.toJson(), {'diagram': 'MY DIAGRAM'});
      expect(output.toText(), 'MY DIAGRAM');
    });
  });
}
