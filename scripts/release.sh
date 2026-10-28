#!/usr/bin/env bash
# Builds a downloadable Poppy: a universal (arm64 + x86_64) Poppy.app signed with a Developer ID,
# notarized and stapled, in a signed and notarized build/dist/Poppy-<version>.dmg (DESIGN §12.3).
# Never touches build/Poppy.app or the installed Poppy.
# Usage (works from any directory):
#   ./scripts/release.sh                 needs a "Developer ID Application" certificate and the
#                                        notarytool profile below
#   ./scripts/release.sh --no-notarize   sign and package only (e.g. to check the build)
# POPPY_SIGN_IDENTITY picks the certificate; POPPY_NOTARY_PROFILE the Keychain profile saved with
#   xcrun notarytool store-credentials poppy-notary --apple-id <Apple ID> --team-id <Team ID>
set -euo pipefail
cd "$(dirname "$0")/.."

fail() { echo "release: $*" >&2; exit 1; }

NOTARIZE=1
case "${1:-}" in
    --no-notarize) NOTARIZE=0 ;;
    "") ;;
    *) echo "usage: $0 [--no-notarize]" >&2; exit 2 ;;
esac
PROFILE="${POPPY_NOTARY_PROFILE:-poppy-notary}"

identity="${POPPY_SIGN_IDENTITY:-}"
if [[ -z "$identity" ]]; then
    identity=$(security find-identity -v -p codesigning 2>/dev/null \
        | grep -E '"Developer ID Application:' | head -1 | awk '{print $2}' || true)
fi
[[ -n "$identity" ]] || fail "no Developer ID Application certificate found. Create one in Xcode → Settings → Accounts → Manage Certificates."
if (( NOTARIZE )); then
    xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1 \
        || fail "no notarytool profile \"$PROFILE\". Save one with: xcrun notarytool store-credentials $PROFILE --apple-id <Apple ID> --team-id <Team ID>"
fi

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
DIST=build/dist
APP="$DIST/Poppy.app"
DMG="$DIST/Poppy-$VERSION.dmg"

# One build per architecture, joined with lipo. (`swift build --arch arm64 --arch x86_64`
# goes through xcbuild, which fails on SwiftTerm's build plugin.) Its own build folder, so
# Poppy Dev's and install.sh's caches stay.
binaries=()
for arch in arm64 x86_64; do
    build=(swift build -c release --triple "$arch-apple-macosx14.0" --scratch-path .build-dist)
    "${build[@]}"
    binaries+=("$("${build[@]}" --show-bin-path)/poppy")
done

rm -rf "$DIST"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Logos"
lipo -create -output "$APP/Contents/MacOS/poppy" "${binaries[@]}"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/Logos/*.png Resources/Logos/src/LICENSE-lobe-icons "$APP/Contents/Resources/Logos/"

# Notarization needs the hardened runtime and a secure timestamp.
codesign --force --options runtime --timestamp --sign "$identity" "$APP"
codesign --verify --strict --verbose=2 "$APP"
echo "Signed with $(codesign -dvv "$APP" 2>&1 | sed -n 's/^Authority=//p' | head -1)"

notarize() {
    xcrun notarytool submit "$1" --keychain-profile "$PROFILE" --wait
}

# The app is notarized and stapled first, so it opens offline once copied out of the DMG.
if (( NOTARIZE )); then
    ditto -c -k --keepParent "$APP" "$DIST/Poppy.zip"
    notarize "$DIST/Poppy.zip"
    rm "$DIST/Poppy.zip"
    xcrun stapler staple "$APP"
fi

staging="$DIST/dmg"
mkdir -p "$staging"
ditto "$APP" "$staging/Poppy.app"
ln -s /Applications "$staging/Applications"
hdiutil create -volname "Poppy $VERSION" -srcfolder "$staging" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
rm -rf "$staging"
codesign --force --timestamp --sign "$identity" "$DMG"

if (( NOTARIZE )); then
    notarize "$DMG"
    xcrun stapler staple "$DMG"
    spctl --assess --type open --context context:primary-signature --verbose "$DMG"
fi

echo "Built $DMG"
