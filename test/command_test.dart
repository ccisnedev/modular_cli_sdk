import 'package:modular_cli_sdk/modular_cli_sdk.dart';
import 'package:test/test.dart';

// ── Test doubles ────────────────────────────────────────────────────────────

class _GreetInput extends Input {
  final String name;
  _GreetInput({required this.name});

  @override
  Map<String, dynamic> toJson() => {'name': name};
}

class _GreetOutput extends Output {
  final String greeting;
  _GreetOutput({required this.greeting});

  @override
  Map<String, dynamic> toJson() => {'greeting': greeting};

  @override
  int get exitCode => ExitCode.ok;
}

class _ValidGreetCommand implements Command<_GreetInput, _GreetOutput> {
  @override
  final _GreetInput input;
  _ValidGreetCommand(this.input);

  @override
  String? validate() => null;

  @override
  Future<_GreetOutput> execute() async =>
      _GreetOutput(greeting: 'Hello, ${input.name}!');
}

class _InvalidGreetCommand implements Command<_GreetInput, _GreetOutput> {
  @override
  final _GreetInput input;
  _InvalidGreetCommand(this.input);

  @override
  String? validate() => input.name.isEmpty ? 'name must not be empty' : null;

  @override
  Future<_GreetOutput> execute() async =>
      _GreetOutput(greeting: 'Hello, ${input.name}!');
}

class _FailingCommand implements Command<_GreetInput, _GreetOutput> {
  @override
  final _GreetInput input;
  _FailingCommand(this.input);

  @override
  String? validate() => null;

  @override
  Future<_GreetOutput> execute() async {
    throw CommandException(
      code: 'BROKEN',
      message: 'Something went wrong',
      exitCode: ExitCode.genericError,
    );
  }
}

// ── Tests ───────────────────────────────────────────────────────────────────

void main() {
  group('Command', () {
    test('should accept input and expose it', () {
      final cmd = _ValidGreetCommand(_GreetInput(name: 'Alice'));
      expect(cmd.input.name, 'Alice');
    });

    test('should return null from validate() when input is valid', () {
      final cmd = _InvalidGreetCommand(_GreetInput(name: 'Alice'));
      expect(cmd.validate(), isNull);
    });

    test(
      'should return error string from validate() when input is invalid',
      () {
        final cmd = _InvalidGreetCommand(_GreetInput(name: ''));
        expect(cmd.validate(), 'name must not be empty');
      },
    );

    test('should execute and return Output', () async {
      final cmd = _ValidGreetCommand(_GreetInput(name: 'World'));
      final output = await cmd.execute();
      expect(output.toJson(), {'greeting': 'Hello, World!'});
      expect(output.exitCode, ExitCode.ok);
    });

    test('should throw CommandException on business rule failure', () {
      final cmd = _FailingCommand(_GreetInput(name: 'X'));
      expect(cmd.execute(), throwsA(isA<CommandException>()));
    });

    test('concrete Command should complete full lifecycle', () async {
      final input = _GreetInput(name: 'World');
      final cmd = _ValidGreetCommand(input);

      // validate
      expect(cmd.validate(), isNull);

      // execute
      final output = await cmd.execute();
      expect(output.greeting, 'Hello, World!');
      expect(output.exitCode, 0);
    });
  });
}
