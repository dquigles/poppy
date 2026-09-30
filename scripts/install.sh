#!/usr/bin/env bash
# Builds Poppy from source, installs Poppy.app and the `poppy` command (DESIGN §12).
# Usage: ./scripts/install.sh (works from any directory)
#   APP_DIR=~/Applications ./scripts/install.sh   install the app somewhere else
#   BIN_DIR=/usr/local/bin ./scripts/install.sh   put the `poppy` command somewhere else
set -euo pipefail
cd "$(dirname "$0")/.."

fail() { echo "install: $*" >&2; exit 1; }

# Toolchain: Swift 6.2+ and the macOS 26 SDK (Liquid Glass), i.e. Xcode 26 or its Command Line Tools.
command -v swift >/dev/null || fail "Swift not found. Install Xcode 26 or run: xcode-select --install"
swift_version=$(swift --version 2>/dev/null | sed -nE 's/.*Swift version ([0-9]+)\.([0-9]+).*/\1 \2/p' | head -1)
read -r major minor <<<"${swift_version:-0 0}"
if (( major < 6 || (major == 6 && minor < 2) )); then
    fail "Swift 6.2 or newer is needed (found ${major}.${minor}). Install Xcode 26 or its Command Line Tools."
fi
sdk_major=$(xcrun --sdk macosx --show-sdk-version 2>/dev/null | cut -d. -f1)
if (( ${sdk_major:-0} < 26 )); then
    fail "The macOS 26 SDK is needed (found ${sdk_major:-none}). Install Xcode 26 or its Command Line Tools."
fi

./scripts/bundle.sh

# /Applications if writable, otherwise ~/Applications.
if [[ -z "${APP_DIR:-}" ]]; then
    if [[ -w /Applications ]]; then APP_DIR=/Applications; else APP_DIR="$HOME/Applications"; fi
fi
APP="$APP_DIR/Poppy.app"
mkdir -p "$APP_DIR"

# Stop a running Poppy so the new build replaces it (its agent gets SIGHUP when the
# terminal closes). A signal, not an AppleScript quit, which would ask for Automation access.
if pgrep -xq poppy; then
    echo "Stopping the running Poppy…"
    pkill -x poppy || true
    for _ in {1..20}; do pgrep -xq poppy || break; sleep 0.25; done
fi

rm -rf "$APP"
ditto build/Poppy.app "$APP"
echo "Installed $APP"

# The `poppy` shell command: a tiny wrapper around the app's own binary in client mode (DESIGN §9.9).
BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"
mkdir -p "$BIN_DIR"
cat >"$BIN_DIR/poppy" <<EOF
#!/bin/sh
# Installed by Poppy's scripts/install.sh. Set POPPY_APP to use a Poppy.app elsewhere.
exec "\${POPPY_APP:-$APP}/Contents/MacOS/poppy" --cli "\$@"
EOF
chmod 755 "$BIN_DIR/poppy"
echo "Installed $BIN_DIR/poppy"

case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) echo
       echo "Note: $BIN_DIR is not on your PATH. Add this to ~/.zshrc, then open a new terminal:"
       echo "  export PATH=\"$BIN_DIR:\$PATH\"" ;;
esac
if grep -qsE '^[[:space:]]*(function[[:space:]]+)?poppy[[:space:]]*\(\)' "$HOME/.zshrc" "$HOME/.bashrc" 2>/dev/null; then
    echo
    echo "Note: a poppy() shell function in your ~/.zshrc or ~/.bashrc takes precedence over $BIN_DIR/poppy."
    echo "Remove it, or point it at $APP."
fi

open "$APP"
echo
echo "Poppy is running: look for the pill in the bottom-right corner, or press ⌃⌥Space."
