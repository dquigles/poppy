#!/usr/bin/env bash
# Builds build/Poppy.app: release binary + Info.plist, ad-hoc signed (DESIGN §12).
# Usage: ./scripts/bundle.sh (works from any directory)
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Poppy.app"

swift build -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$(swift build -c release --show-bin-path)/poppy" "$APP/Contents/MacOS/poppy"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# SwiftTerm's resource bundle (Metal shaders) is intentionally not copied:
# the Metal renderer is off and SwiftTerm doesn't load it via Bundle.module.

codesign --force --deep --sign - "$APP"

echo "Built $APP"
