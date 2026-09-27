# Template installer for a CLI built on modular_cli_sdk's InstallationPlugin.
#
# This is a template, not a script this package runs: copy it into your own
# CLI's repository (e.g. as `install.ps1` at the repository root) and edit
# only the four values in the "Configure your CLI here" block below. Nothing
# else needs to change to match what InstallationPlugin expects on disk.
#
# Extracted from inquiry's own install.ps1 (the canonical reference among
# the CLIs this was extracted from), then strengthened: inquiry's bootstrap
# installer removes the previous install directory before extracting the new
# one; this template stages the new install fully in a temporary directory
# first, and only replaces the previous install once every file is in place,
# so a failed download or a failed extraction never leaves a working install
# half-replaced.

$ErrorActionPreference = 'Stop'

# ---- Configure your CLI here -------------------------------------------
$RepoOwner = 'you'
$RepoName = 'mycli'
$ExecutableName = 'mycli'       # the file inside bin/, without .exe
$AliasName = 'mc'               # a short second name; must differ from
                                 # $ExecutableName (see README's "Adopting
                                 # InstallationPlugin" section for why)
$AssetName = "$RepoName-windows-x64.zip"
# -------------------------------------------------------------------------

$InstallDir = Join-Path $env:LOCALAPPDATA $RepoName
$BinDir = Join-Path $InstallDir 'bin'
$ExePath = Join-Path $BinDir "$ExecutableName.exe"
$AliasPath = Join-Path $BinDir "$AliasName.cmd"

function Get-LatestReleaseUrl {
    $uri = "https://api.github.com/repos/$RepoOwner/$RepoName/releases/latest"
    $release = Invoke-RestMethod -Uri $uri -Headers @{ 'User-Agent' = 'install.ps1' }
    $asset = $release.assets | Where-Object { $_.name -eq $AssetName } | Select-Object -First 1
    if (-not $asset) {
        throw "Release $($release.tag_name) has no asset named $AssetName."
    }
    return $asset.browser_download_url
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "$RepoName-install-$([guid]::NewGuid())"
$stagingDir = Join-Path $tempRoot 'staging'
$zipPath = Join-Path $tempRoot $AssetName
New-Item -ItemType Directory -Path $stagingDir -Force | Out-Null

try {
    Write-Host "Downloading $AssetName..."
    Invoke-WebRequest -Uri (Get-LatestReleaseUrl) -OutFile $zipPath

    Write-Host 'Extracting...'
    Expand-Archive -Path $zipPath -DestinationPath $stagingDir -Force

    $stagedExe = Join-Path $stagingDir "bin\$ExecutableName.exe"
    if (-not (Test-Path $stagedExe)) {
        throw "Expected $stagedExe after extracting $AssetName, found nothing there."
    }

    # Staged swap: the previous install, if any, is moved aside rather than
    # deleted outright, so a failure partway through this block still has
    # something to restore from.
    $backupDir = $null
    if (Test-Path $InstallDir) {
        $backupDir = "$InstallDir.old-$([guid]::NewGuid())"
        Rename-Item -Path $InstallDir -NewName (Split-Path $backupDir -Leaf)
    }

    try {
        Move-Item -Path $stagingDir -Destination $InstallDir
    } catch {
        if ($backupDir) {
            Remove-Item -Path $InstallDir -Recurse -Force -ErrorAction SilentlyContinue
            Rename-Item -Path $backupDir -NewName (Split-Path $InstallDir -Leaf)
        }
        throw
    }

    if ($backupDir -and (Test-Path $backupDir)) {
        Remove-Item -Path $backupDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    # Windows never gets a symlink alias here: it always needs an elevated
    # prompt or Developer Mode that an installer cannot assume, so the alias
    # is a `.cmd` shim instead, exactly what
    # CliInstallationConfig.aliasStrategyFor defaults 'windows' to.
    Set-Content -Path $AliasPath -Value "@`"%~dp0$ExecutableName.exe`" %*" -Encoding ASCII

    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if (-not ($userPath -split ';' | Where-Object { $_ -eq $BinDir })) {
        [Environment]::SetEnvironmentVariable('Path', "$userPath;$BinDir", 'User')
        Write-Host "Added $BinDir to your user PATH. Restart your terminal to pick it up."
    }

    Write-Host "$ExecutableName installed to $ExePath"
} finally {
    Remove-Item -Path $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
