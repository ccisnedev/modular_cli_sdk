@TestOn('mac-os')
library;

/// `PlatformOps.current()` on macOS. Only Windows and Linux are supported —
/// macOS was removed before 0.8.0 shipped (no macss or inquiry precedent to
/// extract from; see docs/installation-parity.md and the open questions in
/// PR #33). This mirrors exactly what both source CLIs' own
/// `PlatformOps.current()` factories already do: branch on
/// `Platform.isWindows` / `Platform.isLinux` and throw `UnsupportedError`
/// for anything else.
///
/// Guarded by `@TestOn('mac-os')` rather than mocking `Platform`: there is
/// no OS-injection seam on this factory (mirroring both source CLIs, which
/// have none either), so this only runs where it can actually observe
/// `Platform.isMacOS` being true, and is skipped everywhere else.
import 'package:modular_cli_sdk/modular_cli_sdk.dart';
import 'package:test/test.dart';

void main() {
  test('throws UnsupportedError, the same as macss and inquiry', () {
    expect(
      () => PlatformOps.current(
        executable: 'cx',
        assets: const {
          'linux': 'cx-linux',
          'macos': 'cx-macos',
          'windows': 'cx-windows.exe',
        },
      ),
      throwsUnsupportedError,
    );
  });
}
