import '../cli_plugin.dart';
import '../exit_codes.dart';
import '../input.dart';
import '../output.dart';
import '../query.dart';

/// `doctor` runs every check contributed to the `doctor.checks` extension
/// point and reports them together.
///
/// `DoctorPlugin` owns the extension point but contributes nothing to it
/// itself: on its own, `doctor` reports no checks at all and exits `0`. A
/// plugin that wants to be checked ([InstallationPlugin] is the one this SDK
/// ships) declares `modular_cli.doctor` in its own
/// [CliPluginManifest.requires] and contributes [CliDoctorCheck]s in its
/// `setup`, which dependency ordering guarantees runs after this plugin's own.
class DoctorPlugin implements CliPlugin {
  const DoctorPlugin();

  /// The extension point a plugin contributes a [CliDoctorCheck] to.
  static const extensionPoint = 'doctor.checks';

  @override
  CliPluginManifest get manifest => const CliPluginManifest(
    id: 'modular_cli.doctor',
    displayName: 'Doctor',
    version: '1.0.0',
    hostApiVersion: '^$cliPluginHostApiVersion',
  );

  @override
  void setup(CliPluginHost host) {
    host.declareExtensionPoint<CliDoctorCheck>(extensionPoint);
    host.registerQuery<DoctorInput, DoctorOutput>(
      'doctor',
      (req) => DoctorQuery(
        DoctorInput(),
        host.contributions<CliDoctorCheck>(extensionPoint),
      ),
      description: "Check this CLI's installation",
    );
  }
}

/// One thing `doctor` can check. Named ([name]) because two contributed
/// checks may report on the same topic from different plugins, and a reader
/// (human or `--json`) needs to tell them apart without inspecting which
/// plugin contributed which. Two checks are also free to share a [name]: a
/// result is kept per check that ran, not per name, so one does not
/// overwrite the other.
class CliDoctorCheck {
  const CliDoctorCheck({required this.name, required this.run});

  final String name;

  /// Perform the check. Expected not to throw: a check that cannot run
  /// should itself report that as a [CliCheckStatus.warning] or
  /// [CliCheckStatus.error] result, but [DoctorQuery.execute] does not
  /// depend on that: a check that throws anyway is caught there, recorded as
  /// an error naming the reason, and does not stop the checks after it from
  /// running.
  final Future<CliCheckResult> Function() run;
}

enum CliCheckStatus { ok, warning, error }

class CliCheckResult {
  const CliCheckResult({required this.status, required this.message});

  final CliCheckStatus status;
  final String message;

  Map<String, dynamic> toJson() => {'status': status.name, 'message': message};
}

/// One [CliDoctorCheck]'s result, paired with the name it ran under, in the
/// order the check ran.
class CliDoctorEntry {
  const CliDoctorEntry({required this.name, required this.result});

  final String name;
  final CliCheckResult result;

  Map<String, dynamic> toJson() => {
    'name': name,
    'status': result.status.name,
    'detail': result.message,
  };
}

class DoctorInput extends Input {
  DoctorInput();

  @override
  Map<String, dynamic> toJson() => const {};
}

class DoctorOutput extends Output {
  DoctorOutput(this.results);

  /// Every check's result, in the order the checks ran. A list, not a map
  /// keyed by name: two checks sharing a name are both kept, rather than the
  /// later one silently overwriting the earlier one's result (and, with it,
  /// an error the earlier check found).
  final List<CliDoctorEntry> results;

  bool get hasError =>
      results.any((e) => e.result.status == CliCheckStatus.error);

  @override
  Map<String, dynamic> toJson() => {
    'checks': [for (final entry in results) entry.toJson()],
  };

  @override
  String? toText() => results.isEmpty
      ? 'No doctor checks are registered.'
      : results
            .map(
              (e) =>
                  '${e.result.status.name.padRight(7)} ${e.name}: ${e.result.message}',
            )
            .join('\n');

  // A warning is reported, never punished with a non-zero exit: it names
  // something worth a look (a newer release, a lookup that failed) that
  // the CLI still works despite. Only a check that found something actually
  // wrong, or a check that itself failed to run, moves `doctor` to
  // ExitCode.configError, computed from every result rather than from
  // whichever one happened to run last.
  @override
  int get exitCode => hasError ? ExitCode.configError : ExitCode.ok;
}

class DoctorQuery implements Query<DoctorInput, DoctorOutput> {
  DoctorQuery(this.input, this.checks);

  @override
  final DoctorInput input;

  final List<CliDoctorCheck> checks;

  @override
  String? validate() => null;

  @override
  Future<DoctorOutput> execute() async {
    final results = <CliDoctorEntry>[];
    for (final check in checks) {
      CliCheckResult result;
      try {
        result = await check.run();
      } on Object catch (e) {
        // A check that throws instead of honoring its own contract does not
        // take the rest of `doctor` down with it: caught here, turned into
        // the same error shape a well-behaved check would have reported,
        // named by the check that failed and the reason it gave.
        result = CliCheckResult(
          status: CliCheckStatus.error,
          message: 'Check "${check.name}" failed to run: $e',
        );
      }
      results.add(CliDoctorEntry(name: check.name, result: result));
    }
    return DoctorOutput(results);
  }
}
