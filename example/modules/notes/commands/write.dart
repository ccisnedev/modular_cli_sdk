/// `notes write <name> --plan|--apply` — the example's one writing command.
///
/// It exists to demonstrate the half of the SDK a query cannot show: a route
/// that changes something, states what it would change before anything runs,
/// and is held to it.
library;

import 'dart:io';

import 'package:cli_router/cli_router.dart';
import 'package:modular_cli_sdk/modular_cli_sdk.dart';

// ─── Input ──────────────────────────────────────────────────────────────────

class WriteNoteInput extends Input {
  WriteNoteInput({required this.name, required this.directory, this.body});

  final String name;
  final String directory;
  final String? body;

  factory WriteNoteInput.fromCliRequest(CliRequest req) => WriteNoteInput(
    name: req.param('name') ?? '',
    directory: req.flagString('dir') ?? 'notes',
    body: req.flagString('body'),
  );

  /// `--plan`, `--apply` and `--autoapprove` are **not** here: the SDK adds
  /// them to every command, and adding them by hand is how twelve commands in
  /// one CLI ended up each declaring the same three flags.
  static final List<CliParam> params = [
    CliParam.positional('name', description: 'Name of the note'),
    CliParam.string(
      'dir',
      defaultValue: 'notes',
      description: 'Directory the note is written into',
    ),
    CliParam.string('body', description: 'What the note says'),
  ];

  @override
  List<CliParam> get schemaFields => params;

  @override
  Map<String, dynamic> toJson() => {'name': name, 'dir': directory};

  String get path => '$directory/$name.md';
}

// ─── Output ─────────────────────────────────────────────────────────────────

/// What the command produced — and nothing else. No `planPath`, no `blocked`,
/// no `message`: those describe the gate, and the gate is the SDK's.
class WriteNoteOutput extends Output {
  WriteNoteOutput({required this.written, required this.kept});

  final List<String> written;
  final List<String> kept;

  @override
  Map<String, dynamic> toJson() => {'written': written, 'kept': kept};

  @override
  String? toText() => [
    ...written.map((p) => 'written  $p'),
    ...kept.map((p) => 'kept     $p'),
  ].join('\n');

  @override
  int get exitCode => ExitCode.ok;
}

// ─── Steps ──────────────────────────────────────────────────────────────────

/// Creates the directory, unless it is already there.
class EnsureDirectory implements Step {
  EnsureDirectory(this.path);

  final String path;

  @override
  Preview preview() => Directory(path).existsSync()
      ? Preview(verb: 'exists', target: path)
      : Preview(verb: 'create', target: path);

  @override
  Future<Outcome> perform(StepContext context) async {
    if (Directory(path).existsSync()) {
      return Outcome(verb: 'exists', target: path);
    }
    Directory(path).createSync(recursive: true);
    return Outcome(verb: 'create', target: path);
  }
}

/// Writes the note, or keeps the one that is already there.
///
/// `contents` is settled when the step is built, not derived again inside
/// [perform]. Deriving it twice is how the preview and the work come to
/// describe different changes.
class WriteNote implements Step {
  WriteNote(this.path, this.contents);

  final String path;
  final String contents;

  @override
  Preview preview() => File(path).existsSync()
      ? Preview(verb: 'keep', target: path, detail: 'already exists')
      : Preview(
          verb: 'create',
          target: path,
          detail: '${contents.length} characters',
        );

  @override
  Future<Outcome> perform(StepContext context) async {
    if (File(path).existsSync()) {
      return Outcome(verb: 'keep', target: path);
    }
    File(path).writeAsStringSync(contents);
    return Outcome(verb: 'create', target: path);
  }
}

// ─── Command ────────────────────────────────────────────────────────────────

class WriteNoteCommand implements Command<WriteNoteInput, WriteNoteOutput> {
  WriteNoteCommand(this.input);

  @override
  final WriteNoteInput input;

  @override
  String? validate() => input.name.isEmpty ? 'a <name> is required' : null;

  @override
  Future<List<Step>> steps() async => [
    EnsureDirectory(input.directory),
    WriteNote(input.path, '# ${input.name}\n\n${input.body ?? ''}\n'),
  ];

  @override
  WriteNoteOutput describe(Execution execution) => WriteNoteOutput(
    written: [
      for (final o in execution.outcomes)
        if (o.verb == 'create') o.target,
    ],
    kept: [
      for (final o in execution.outcomes)
        if (o.verb == 'keep' || o.verb == 'exists') o.target,
    ],
  );
}
