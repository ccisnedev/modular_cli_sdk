/// Doubles shared by the tests that exercise queries and commands.
///
/// They live here rather than being repeated per file so that a change to the
/// [Query] or [Command] contract breaks one place, not six.
library;

import 'dart:convert';
import 'dart:io';

// `Step`, `Preview`, `Outcome` and `Execution` arrive through here: the SDK
// re-exports them so a command author imports one package.
import 'package:modular_cli_sdk/modular_cli_sdk.dart';

// ── Sink ────────────────────────────────────────────────────────────────────

/// An [IOSink] that keeps what was written to it.
class MemorySink implements IOSink {
  final StringBuffer _buffer = StringBuffer();

  String get output => _buffer.toString();

  @override
  void write(Object? object) => _buffer.write(object);
  @override
  void writeln([Object? object = '']) {
    _buffer.write(object);
    _buffer.write('\n');
  }

  @override
  void writeAll(Iterable objects, [String separator = '']) =>
      _buffer.writeAll(objects, separator);
  @override
  void writeCharCode(int charCode) => _buffer.writeCharCode(charCode);
  @override
  void add(List<int> data) => _buffer.write(utf8.decode(data));
  @override
  void addError(Object error, [StackTrace? stackTrace]) {}
  @override
  Future addStream(Stream<List<int>> stream) async {
    await for (final data in stream) {
      add(data);
    }
  }

  @override
  Future flush() async {}
  @override
  Future close() async {}
  @override
  Future get done => Future.value();
  @override
  Encoding encoding = utf8;
}

// ── A query ─────────────────────────────────────────────────────────────────

class CountInput extends Input {
  CountInput(this.count);
  final int count;

  @override
  Map<String, dynamic> toJson() => {'count': count};
}

class CountOutput extends Output {
  CountOutput(this.count);
  final int count;

  @override
  Map<String, dynamic> toJson() => {'count': count};

  @override
  int get exitCode => ExitCode.ok;
}

class CountQuery implements Query<CountInput, CountOutput> {
  CountQuery(this.input);

  @override
  final CountInput input;

  @override
  String? validate() => input.count < 0 ? 'cannot count backwards' : null;

  @override
  Future<CountOutput> execute() async => CountOutput(input.count);
}

// ── A command ───────────────────────────────────────────────────────────────

class TouchInput extends Input {
  TouchInput();

  @override
  Map<String, dynamic> toJson() => const {};
}

class TouchOutput extends Output {
  TouchOutput(this.touched);

  /// What the run actually reported doing.
  final List<String> touched;

  @override
  Map<String, dynamic> toJson() => {'touched': touched};

  @override
  int get exitCode => ExitCode.ok;

  @override
  String? toText() => 'touched: ${touched.join(', ')}';
}

/// A command whose steps do nothing observable outside the test.
class TouchCommand
    implements Command<TouchInput, TouchOutput>, ExplainsNothingToDo {
  TouchCommand(
    this.input, {
    this.targets = const ['a.txt'],
    this.error,
    this.explanation,
  });

  /// What this command says when it builds no steps. Null accepts the
  /// framework's wording.
  final String? explanation;

  /// Whether the framework asked, and when — a reason read before `steps()`
  /// would be read before the command had worked it out.
  bool askedBeforeSteps = false;
  bool _stepsBuilt = false;

  @override
  String? get nothingToDo {
    if (!_stepsBuilt) askedBeforeSteps = true;
    return explanation;
  }

  @override
  final TouchInput input;

  final List<String> targets;

  /// When set, the first step throws instead of reporting.
  final Object? error;

  /// The steps this command built, kept so a test can ask whether they ran.
  final List<FakeStep> built = [];

  @override
  String? validate() => null;

  @override
  Future<List<Step>> steps() async {
    _stepsBuilt = true;
    built
      ..clear()
      ..addAll([
        for (final target in targets)
          FakeStep(
            verb: 'create',
            target: target,
            throws: target == targets.first ? error : null,
          ),
      ]);
    return built;
  }

  @override
  TouchOutput describe(Execution execution) =>
      TouchOutput(execution.outcomes.map((o) => o.target).toList());
}

/// A step that records whether it ran, and can be told to misreport or throw.
class FakeStep implements Step {
  FakeStep({
    required this.verb,
    required this.target,
    this.reportedVerb,
    this.throws,
  });

  final String verb;
  final String target;

  /// When set, what the step reports doing — which is not what it claimed.
  final String? reportedVerb;

  final Object? throws;

  bool performed = false;

  @override
  Preview preview() => Preview(verb: verb, target: target);

  @override
  Future<Outcome> perform(StepContext context) async {
    if (throws != null) throw throws!;
    performed = true;
    return Outcome(verb: reportedVerb ?? verb, target: target);
  }
}

/// A command that builds no steps and never heard of [ExplainsNothingToDo].
///
/// The interface is opt-in, so this is what keeps the change additive: a
/// command written before it existed must behave exactly as it did.
class PlainEmptyCommand implements Command<TouchInput, TouchOutput> {
  PlainEmptyCommand(this.input);

  @override
  final TouchInput input;

  @override
  String? validate() => null;

  @override
  Future<List<Step>> steps() async => const [];

  @override
  TouchOutput describe(Execution execution) => TouchOutput(const []);
}
