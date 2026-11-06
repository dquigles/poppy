#!/usr/bin/env bash
# Compiles Resources/AppIcon.icon (made in Icon Composer, DESIGN §7.11) into Resources/Assets.car
# (the Liquid Glass icon macOS 26 shows) and Resources/AppIcon.icns (for macOS 14–15). Both are
# committed, so building Poppy needs no Xcode: re-run this after saving the icon in Icon Composer.
# Needs Xcode 26 (actool). Usage (works from any directory): ./scripts/compile-app-icon.sh
set -euo pipefail
cd "$(dirname "$0")/.."

out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
xcrun actool --compile "$out" --platform macosx --minimum-deployment-target 14.0 \
    --app-icon AppIcon --output-partial-info-plist "$out/partial.plist" "$PWD/Resources/AppIcon.icon" >/dev/null
cp "$out/Assets.car" "$out/AppIcon.icns" Resources/
echo "wrote Resources/Assets.car and Resources/AppIcon.icns"
