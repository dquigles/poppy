#!/usr/bin/env bash
# Builds an app bundle from the release binary + Info.plist, signed (DESIGN §12).
# Usage (works from any directory):
#   ./scripts/bundle.sh             build/Poppy Dev.app, to test beside the installed Poppy (§12.1)
#   ./scripts/bundle.sh --release   build/Poppy.app, what install.sh installs
set -euo pipefail
cd "$(dirname "$0")/.."

case "${1:-}" in
    --release) DEV=0 ;;
    "") DEV=1 ;;
    *) echo "usage: $0 [--release]" >&2; exit 2 ;;
esac

if (( DEV )); then
    # Its own name, bundle ID, executable (so `pkill -x poppy` in install.sh spares it) and,
    # through the PoppyDev key, its own settings folder, no default hotkey and a DEV tag.
    APP="build/Poppy Dev.app"
    EXECUTABLE="poppy-dev"
else
    APP="build/Poppy.app"
    EXECUTABLE="poppy"
fi

swift build -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$(swift build -c release --show-bin-path)/poppy" "$APP/Contents/MacOS/$EXECUTABLE"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if (( DEV )); then
    plist="$APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $EXECUTABLE" \
        -c "Set :CFBundleIdentifier io.github.dquigles.poppy.dev" \
        -c "Set :CFBundleName Poppy Dev" \
        -c "Add :PoppyDev bool true" "$plist"
fi
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
if (( DEV )); then echo "Run it with: \"$APP/Contents/MacOS/$EXECUTABLE\""; fi
