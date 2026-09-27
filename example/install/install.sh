#!/usr/bin/env bash
# Template installer for a CLI built on modular_cli_sdk's InstallationPlugin.
#
# This is a template, not a script this package runs: copy it into your own
# CLI's repository (e.g. as `install.sh` at the repository root) and edit
# only the values in the "Configure your CLI here" block below. Nothing else
# needs to change to match what InstallationPlugin expects on disk.
#
# Extracted from inquiry's own install.sh (the canonical reference among the
# CLIs this was extracted from), then strengthened: inquiry's bootstrap
# installer removes the previous install directory before extracting the
# new one; this template stages the new install fully in a temporary
# directory first, and only replaces the previous install once every file
# is in place, so a failed download or a failed extraction never leaves a
# working install half-replaced.

set -euo pipefail

# ---- Configure your CLI here -------------------------------------------
REPO_OWNER="you"
REPO_NAME="mycli"
EXECUTABLE_NAME="mycli"
ALIAS_NAME="mc"        # a short second name; must differ from
                        # EXECUTABLE_NAME (see README's "Adopting
                        # InstallationPlugin" section for why)
# -------------------------------------------------------------------------

case "$(uname -s)" in
  Darwin) ASSET_NAME="${REPO_NAME}-macos-x64.tar.gz" ;;
  Linux) ASSET_NAME="${REPO_NAME}-linux-x64.tar.gz" ;;
  *) echo "Unsupported OS: $(uname -s)" >&2; exit 1 ;;
esac

INSTALL_DIR="$HOME/.${REPO_NAME}"
BIN_DIR="$INSTALL_DIR/bin"
LOCAL_BIN="$HOME/.local/bin"
EXE_PATH="$BIN_DIR/$EXECUTABLE_NAME"
ALIAS_LINK="$LOCAL_BIN/$ALIAS_NAME"
EXE_LINK="$LOCAL_BIN/$EXECUTABLE_NAME"

TEMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEMP_ROOT"' EXIT

echo "Fetching latest release metadata..."
DOWNLOAD_URL="$(
  curl -fsSL -H 'User-Agent: install.sh' \
    "https://api.github.com/repos/$REPO_OWNER/$REPO_NAME/releases/latest" \
    | grep -o "\"browser_download_url\": *\"[^\"]*${ASSET_NAME}\"" \
    | head -n 1 \
    | sed -E 's/.*"(https[^"]+)"/\1/'
)"
if [ -z "$DOWNLOAD_URL" ]; then
  echo "Latest release has no asset named $ASSET_NAME." >&2
  exit 1
fi

echo "Downloading $ASSET_NAME..."
ARCHIVE_PATH="$TEMP_ROOT/$ASSET_NAME"
curl -fsSL -o "$ARCHIVE_PATH" "$DOWNLOAD_URL"

echo "Extracting..."
STAGING_DIR="$TEMP_ROOT/staging"
mkdir -p "$STAGING_DIR"
tar xzf "$ARCHIVE_PATH" -C "$STAGING_DIR"

STAGED_EXE="$STAGING_DIR/bin/$EXECUTABLE_NAME"
if [ ! -f "$STAGED_EXE" ]; then
  echo "Expected $STAGED_EXE after extracting $ASSET_NAME, found nothing there." >&2
  exit 1
fi
chmod +x "$STAGED_EXE"

# Staged swap: the previous install, if any, is moved aside rather than
# deleted outright, so a failure partway through this block still has
# something to restore from.
BACKUP_DIR=""
if [ -d "$INSTALL_DIR" ]; then
  BACKUP_DIR="$INSTALL_DIR.old-$$"
  mv "$INSTALL_DIR" "$BACKUP_DIR"
fi

restore_backup() {
  if [ -n "$BACKUP_DIR" ] && [ -d "$BACKUP_DIR" ]; then
    rm -rf "$INSTALL_DIR"
    mv "$BACKUP_DIR" "$INSTALL_DIR"
  fi
}

if ! mv "$STAGING_DIR" "$INSTALL_DIR"; then
  restore_backup
  exit 1
fi

if [ -n "$BACKUP_DIR" ] && [ -d "$BACKUP_DIR" ]; then
  rm -rf "$BACKUP_DIR"
fi

mkdir -p "$LOCAL_BIN"
ln -sf "$EXE_PATH" "$EXE_LINK"
ln -sf "$EXE_PATH" "$ALIAS_LINK"

case ":$PATH:" in
  *":$LOCAL_BIN:"*) ;;
  *)
    echo "Add $LOCAL_BIN to your PATH (e.g. in ~/.bashrc or ~/.zshrc):"
    echo "  export PATH=\"$LOCAL_BIN:\$PATH\""
    ;;
esac

echo "$EXECUTABLE_NAME installed to $EXE_PATH"
