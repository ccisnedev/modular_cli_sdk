# InstallationPlugin 0.8.0: parity with the CLIs it is extracted from

`InstallationPlugin` 0.8.0 (issue [#31](https://github.com/macss-dev/modular_cli_sdk/issues/31))
replaces the SDK-original design shipped in 0.7.0 (issue #28) with an
extraction of macss's and inquiry's own `upgrade`/`uninstall` commands, which
already work in production. This table is the accounting for that
extraction: what each CLI does today, on `origin/main` of its own repository,
against what the plugin does now, row by row, with a status of `equal`
(same behavior, ported) or `differs (reason)` (the plugin does not, and
should not, replicate this).

docmd and skillwire are included for completeness, since both also depend on
`modular_cli_sdk`, but neither is a source for this extraction: docmd never
adopted the plugin system for installation, and skillwire has no
upgrade/uninstall/doctor commands at all. Both rows below are "CLI today"
only, to show why.

## macss and inquiry: the two sources of this extraction

| Row | macss (CLI today) | inquiry (CLI today) | InstallationPlugin 0.8.0 | Status |
| --- | --- | --- | --- | --- |
| Install directory | `p.dirname(p.dirname(Platform.resolvedExecutable))` — derived from the running binary, never looked up on `PATH` | Same derivation | Same derivation, in `installation_plugin.dart` | equal |
| Release lookup | `GET /repos/{repo}/releases/latest` (no tag prefix in use) | Same, `/releases/latest` | `HttpCliReleaseSource.latestRelease`; `listReleases` (paginated, following `Link: rel="next"`) only when `tagPrefix` is configured, matching neither CLI's own need for one today but expressible for a CLI that does | equal (latest); `tagPrefix` path is new surface, unexercised by either CLI |
| Asset selection | Asset named for `Platform.operatingSystem`, from a per-OS name table | Same | `assetForPlatform(release, config.assets, Platform.operatingSystem)` | equal |
| Archive extraction | `platform_ops.dart`: PowerShell `Expand-Archive` (Windows), `tar xzf` (Linux) | Same two implementations, own `platform_ops.dart` | `WindowsPlatformOps`/`LinuxPlatformOps.expandArchive`, ported | equal |
| macOS support | `PlatformOps.current()` throws `UnsupportedError` for any OS but Windows/Linux (`code/cli/lib/targets/platform_ops.dart`) | Same, throws for anything but Windows/Linux (`code/cli/lib/hosts/platform_ops.dart`) | `MacosPlatformOps` exists and reuses `LinuxPlatformOps`'s behavior (same `tar xzf` extraction, same POSIX PATH handling) | differs — new: neither CLI supports macOS today; see open questions |
| Download destination | Own temp directory (`Directory.systemTemp`), never inside the install directory | Same | `ReplaceInstallation.perform()` downloads into `Directory.systemTemp.createTempSync('cli_upgrade_')`, cleaned up in a `finally` | equal |
| PATH write (upgrade) | Not touched by upgrade; only `install.ps1`/`install.sh` write PATH once, at install time | Same | Same: `upgrade` never calls `setEnvVariable` | equal |
| Alias/shim (`.cmd` / symlink) | Created by `install.ps1` (`.cmd` shim calling `%~dp0<exe>.exe %*`) / `install.sh` (symlink); never touched by `upgrade` or `uninstall` | Same shapes, own `install.ps1`/`install.sh` | Same: `postUpgradeSteps`/no built-in alias handling; the `alias` doctor check only verifies the shape these scripts already produce | equal |
| PATH removal (uninstall) | `UnsetFromPath`: strips the CLI's own `bin` dir from `PATH`, case/normalize-insensitive, only writes back if changed | Same (`uninstall_test.dart`: "removes bin dir from PATH via platformOps" / "does not call setEnvVariable when bin dir is not in PATH") | Ported verbatim as `UnsetFromPath` | equal |
| Directory deletion (uninstall) | `scheduleDeletion`: Windows renames the running exe aside then launches a detached batch script that `rmdir /s /q` after a short delay; Linux spawns a detached `rm -rf`, since the running binary is not locked | Same two implementations | Ported verbatim as `PlatformOps.scheduleDeletion`, wrapped in `DeleteInstallation` | equal |
| Uninstall of a missing install | Not an error: nothing to remove from `PATH`, nothing to delete | Same | Same: `UnsetFromPath` no-ops when the bin dir is not present in `PATH`; `scheduleDeletion` no-ops on a directory that does not exist | equal |
| Extension steps around upgrade/uninstall | None (macss's own `upgrade`/`uninstall` do nothing beyond replace/remove) | `RedeployHosts` after upgrade, `CleanDeployedHosts` before uninstall (`hosts/deployer.dart`) | `CliInstallationConfig.postUpgradeSteps`/`preUninstallSteps`: `List<Step> Function(String installDir, PlatformOps platformOps)`, folded into `UpgradeOutput.extra`/`UninstallOutput.extra` rather than a fixed field | equal in mechanism (a CLI plugs in exactly inquiry's own steps); the callback shape itself is new, since neither CLI needed one before this extraction had to serve both |
| `doctor`: is the binary on PATH | `isOnPath()` in `code/cli/lib/src/tools.dart`, used in `doctor.dart` to check *other* tools (`git`, `gh`, ...), not the CLI's own binary | No `doctor` check for its own binary | New `binary` check, reusing `isOnPath`'s PATH-resolution logic against `config.executable` itself | differs (new) — neither CLI checks its own binary is reachable; both assume it, since `doctor` running at all proves it |
| `doctor`: alias resolves | No such check | No such check | New `alias` check: does `config.alias` resolve to the same binary, when configured | differs (new) |
| `doctor`: newer release available | Not in `doctor`; `version_check.dart`'s `VersionCheckResult` is surfaced in `tui.dart`'s banner instead, and is explicitly "Silent on network failures — returns `updateAvailable = false`" | Same `version_check.dart`, but *is* surfaced as one `doctor` check's `version` field (`doctor.dart:672`, `"$latestVersion available"`) — still silent on lookup failure | New `release` check: warns (never errors) when a newer tagged release exists; unlike both CLIs' own `version_check.dart`, a failed lookup is itself reported (as part of the check's own detail), not swallowed into "no update available" | differs (new check; differs further on lookup-failure visibility — see open questions) |
| Error ids thrown | `StateError`/ad hoc exceptions, not a `CommandException` id scheme (macss predates that convention) | Same | `release-lookup-failed`, `asset-not-found` — the only two ids `installation_plugin.dart` throws | differs (surface, not behavior): the SDK's own error envelope replaces ad hoc exceptions, but the two conditions are the same ones each CLI already treats as fatal |

## docmd (CLI today only — not a source for this extraction)

docmd depends on `modular_cli_sdk` but has never adopted the plugin system
for installation; its `upgrade`/`uninstall`/`doctor` are its own
`Command`/`Query` implementations, unrelated to `InstallationPlugin`, on a
fixed install path rather than one derived from the running binary:

- `code/cli/lib/modules/global/commands/upgrade.dart`: `UpgradeDeps` (a
  hand-rolled DI class of function-typed fields — `fetchJson`, `downloadFile`,
  `execFile`, `deletePath`, `ensureDirectory` — rather than `Step`-based
  `Command`s) resolves a fixed managed path: `%LOCALAPPDATA%\docmd` on
  Windows, `~/.docmd` on Linux (`_resolveManagedInstallPath`); macOS is
  unsupported (returns `null`, then `UnsupportedError`)
- `code/cli/lib/modules/global/commands/uninstall.dart`: `UninstallDeps`,
  the same DI pattern; Windows uninstall calls a `scheduleWindowsRemoval`
  hook (a PowerShell-script-based removal, not the `.cmd`-batch
  `scheduleDeletion` approach macss/inquiry/the plugin use); Linux also
  removes a symlink at `~/.local/bin/docmd` explicitly, rather than a PATH
  entry
- `code/cli/lib/modules/global/commands/doctor.dart`: entirely its own
  `DoctorOutput` (`checks`, `paths`, `capabilities` for document
  ingestion/rendering backends), unrelated to the SDK's `DoctorPlugin`
  extension point; it does its own `updateAvailable` check inline via
  `version_check.dart`, the same silent-on-failure pattern macss/inquiry use

None of this is behavior `InstallationPlugin` 0.8.0 needs to reproduce: the
task is extraction from macss and inquiry, and docmd's own commands keep
working unchanged, on the SDK version they already use, independent of this
plugin.

## skillwire (CLI today only — not a source for this extraction)

skillwire depends on `modular_cli_sdk` `^0.5.0` (before the plugin system
existed) and has no global `upgrade`, `uninstall`, or `doctor` command at
all — `code/cli/lib/modules/` contains only a `skill` module. Its only
installation-related files are static `install.ps1`/`install.sh` scripts
under `code/site/`. There is nothing to compare a row against; skillwire is
listed only to record that it has no installation lifecycle to preserve.

## Open questions

These are judgment calls made while extracting, each already flagged above
in the table's "Status" column, gathered here for review:

1. **macOS.** Neither macss nor inquiry supports macOS; both throw
   `UnsupportedError` from their own `PlatformOps.current()`. The SDK adds
   `MacosPlatformOps`, reusing `LinuxPlatformOps`'s behavior verbatim (same
   `tar xzf` extraction, same POSIX PATH handling), since a shared SDK plugin
   cannot reasonably refuse an entire OS the way a single CLI's own
   installer can. This is new surface with no CLI precedent to extract from.
2. **`selfReplace`.** Neither CLI's own `PlatformOps` exercises a
   self-replace path distinct from "extract the archive over the install
   directory" (`ReplaceInstallation` does not need a separate step: the
   running binary is inside the extracted archive's target either way).
   Not ported as a separate method, since there is nothing to extract.
3. **`release` doctor check and lookup failure.** macss's and inquiry's own
   `version_check.dart` are both explicitly silent on a failed lookup
   (`updateAvailable = false`, no error, no warning). `InstallationPlugin`'s
   `release` check instead reports the lookup failure itself, as part of
   that check's own detail (still only ever a warning, never an error). This
   is a deliberate departure from both CLIs' existing precedent, made
   because doctor is where a person is already looking for this exact kind
   of "something isn't right, but it isn't fatal" signal — worth a second
   look given neither source CLI does it this way.
4. **`postUpgradeSteps`/`preUninstallSteps` callback shape.** Built
   specifically to make inquiry's `RedeployHosts`/`CleanDeployedHosts`
   expressible, since macss needs no such thing at all. The
   `List<Step> Function(String installDir, PlatformOps platformOps)` shape
   is therefore new: it did not exist as a named mechanism in either CLI,
   only as inline steps only inquiry happens to have.
5. **`binary`/`alias` doctor checks.** Adapted, not ported: macss's
   `isOnPath()` (`code/cli/lib/src/tools.dart`) exists, but is only ever used
   in `doctor.dart` to check *other* tools (`git`, `gh`), never the CLI's own
   binary or its alias. Neither CLI checks whether it can find itself.
6. **`environment` injection on `InstallationPlugin`.** Added this
   extraction, narrowly: the `binary`/`alias` checks need to resolve `PATH`
   against something other than the real, shared `Platform.environment` of
   whatever machine runs the SDK's own test suite. This is a testability seam
   for the two SDK-original doctor checks above (item 5), not a port of
   anything either CLI's own tests do.
