import 'package:modular_cli_sdk/modular_cli_sdk.dart';
import 'package:test/test.dart';

/// Concrete Input for testing.
class _TestInput extends Input {
  final String name;
  _TestInput({required this.name});

  @override
  Map<String, dynamic> toJson() => {'name': name};
}

void main() {
  group('Input', () {
    test('should require toJson() implementation', () {
      final input = _TestInput(name: 'Alice');
      expect(input.toJson(), isA<Map<String, dynamic>>());
    });

    test('concrete Input should serialize to JSON', () {
      final input = _TestInput(name: 'Bob');
      expect(input.toJson(), {'name': 'Bob'});
    });
  });
}
