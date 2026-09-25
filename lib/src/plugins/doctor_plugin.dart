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
/// plugin contributed which.
class CliDoctorCheck {
  const CliDoctorCheck({required this.name, required this.run});

  final String name;

  /// Perform the check. Never throws by contract: a check that cannot run
  /// reports that as a [CliCheckStatus.warning] or [CliCheckStatus.error]
  /// result, the same as any other finding, rather than aborting the whole
  /// `doctor` invocation over one check's own failure.
  final Future<CliCheckResult> Function() run;
}

enum CliCheckStatus { ok, warning, error }

class CliCheckResult {
  const CliCheckResult({required this.status, required this.message});

  final CliCheckStatus status;
  final String message;

  Map<String, dynamic> toJson() => {'status': status.name, 'message': message};
}

class DoctorInput extends Input {
  DoctorInput();

  @override
  Map<String, dynamic> toJson() => const {};
}

class DoctorOutput extends Output {
  DoctorOutput(this.results);

  /// Check name → result, in the order the checks were contributed.
  final Map<String, CliCheckResult> results;

  bool get hasError =>
      results.values.any((r) => r.status == CliCheckStatus.error);

  @override
  Map<String, dynamic> toJson() => {
    'checks': {for (final entry in results.entries) entry.key: entry.value.toJson()},
  };

  @override
  String? toText() => results.isEmpty
      ? 'No doctor checks are registered.'
      : results.entries
            .map((e) => '${e.value.status.name.padRight(7)} ${e.key}: ${e.value.message}')
            .join('\n');

  // A warning is reported, never punished with a non-zero exit: it names
  // something worth a look (a newer release, a lookup that failed) that
  // the CLI still works despite. Only a check that found something actually
  // wrong moves `doctor` to ExitCode.configError.
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
    final results = <String, CliCheckResult>{};
    for (final check in checks) {
      results[check.name] = await check.run();
    }
    return DoctorOutput(results);
  }
}
