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
# Harness logos (DESIGN §7.11): the rendered PNGs only, not their SVG sources.
mkdir -p "$APP/Contents/Resources/Logos"
cp Resources/Logos/*.png Resources/Logos/src/LICENSE-lobe-icons "$APP/Contents/Resources/Logos/"
# SwiftTerm's resource bundle (Metal shaders) is intentionally not copied:
# the Metal renderer is off and SwiftTerm doesn't load it via Bundle.module.

# Sign with a certificate if there is one, so the app keeps one identity across rebuilds and
# macOS remembers its Desktop/Documents permissions; ad-hoc signatures change with every build.
# POPPY_SIGN_IDENTITY picks one ("-" forces ad-hoc); otherwise the first Apple Development or
# Developer ID Application identity (a free Apple ID in Xcode creates an Apple Development one).
identity="${POPPY_SIGN_IDENTITY:-}"
if [[ -z "$identity" ]]; then
    identity=$(security find-identity -v -p codesigning 2>/dev/null \
        | grep -E '"(Apple Development|Developer ID Application):' | head -1 | awk '{print $2}' || true)
fi
if [[ -n "$identity" && "$identity" != "-" ]] \
    && codesign --force --deep --timestamp=none --sign "$identity" "$APP"; then
    echo "Signed with $(codesign -dvv "$APP" 2>&1 | sed -n 's/^Authority=//p' | head -1)"
else
    [[ -n "$identity" && "$identity" != "-" ]] && echo "Signing with $identity failed; signing ad-hoc instead."
    codesign --force --deep --sign - "$APP"
fi

echo "Built $APP"
