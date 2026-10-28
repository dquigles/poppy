#!/usr/bin/env bash
# Builds a downloadable Poppy: a universal (arm64 + x86_64) Poppy.app signed with a Developer ID,
# notarized and stapled, in a signed and notarized build/dist/Poppy-<version>.dmg, and the
# Sparkle appcast.xml that announces it (DESIGN §12.3, §12.4). Never touches build/Poppy.app or
# the installed Poppy. .github/workflows/release.yml runs it for a v* tag.
# Usage (works from any directory):
#   ./scripts/release.sh                 needs a "Developer ID Application" certificate, the
#                                        notarytool profile and the Sparkle key below
#   ./scripts/release.sh --no-notarize   sign and package only (e.g. to check the build)
# POPPY_VERSION      the version (default: Info.plist's); the build number is the commit count
# POPPY_SIGN_IDENTITY  the certificate; POPPY_NOTARY_PROFILE the Keychain profile saved with
#   xcrun notarytool store-credentials poppy-notary --apple-id <Apple ID> --team-id <Team ID>
# SPARKLE_PRIVATE_KEY  the update-signing key (CI); otherwise the login Keychain's, account "poppy"
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
REPO=dquigles/poppy
# Sparkle's public key; its private half signs every update (DESIGN §12.4).
SPARKLE_PUBLIC_KEY="9F93ri0zP5xU4KCqY9dzUDbkA2Lxf2M20DdC+igB7YA="
FEED_URL="https://github.com/$REPO/releases/latest/download/appcast.xml"

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

VERSION="${POPPY_VERSION:-$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)}"
[[ "$VERSION" =~ ^[0-9]+(\.[0-9]+)*$ ]] || fail "version \"$VERSION\" isn't like 1.2.3"
# Sparkle compares build numbers; the commit count only grows on main.
BUILD_NUMBER=$(git rev-list --count HEAD)
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
    bin_path="$("${build[@]}" --show-bin-path)"
    binaries+=("$bin_path/poppy")
done
SPARKLE_BIN=.build-dist/artifacts/sparkle/Sparkle/bin

rm -rf "$DIST"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Logos" "$APP/Contents/Frameworks"
lipo -create -output "$APP/Contents/MacOS/poppy" "${binaries[@]}"
cp Resources/Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" \
    -c "Set :CFBundleVersion $BUILD_NUMBER" \
    -c "Add :SUFeedURL string $FEED_URL" \
    -c "Add :SUPublicEDKey string $SPARKLE_PUBLIC_KEY" \
    -c "Add :SUEnableAutomaticChecks bool true" "$APP/Contents/Info.plist"
cp Resources/Logos/*.png Resources/Logos/src/LICENSE-lobe-icons "$APP/Contents/Resources/Logos/"
# Sparkle's framework is universal. Its XPC services are only for sandboxed apps.
ditto "$bin_path/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
rm -rf "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices" \
    "$APP/Contents/Frameworks/Sparkle.framework/XPCServices"

# Inside out, each with the hardened runtime and a secure timestamp (notarization needs both).
sign() { codesign --force --options runtime --timestamp --sign "$identity" "$@"; }
sparkle="$APP/Contents/Frameworks/Sparkle.framework"
sign "$sparkle/Versions/B/Autoupdate"
sign "$sparkle/Versions/B/Updater.app"
sign "$sparkle"
sign "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
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

# The appcast: one item, this DMG, signed with the update key. It's uploaded with each
# release, so the feed URL (the latest release's) always has the newest.
if [[ -n "${SPARKLE_PRIVATE_KEY:-}" ]]; then
    attributes=$(printf '%s' "$SPARKLE_PRIVATE_KEY" | "$SPARKLE_BIN/sign_update" --ed-key-file - "$DMG")
else
    attributes=$("$SPARKLE_BIN/sign_update" --account poppy "$DMG")
fi
cat >"$DIST/appcast.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Poppy</title>
    <item>
      <title>Poppy $VERSION</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <link>https://github.com/$REPO/releases/tag/v$VERSION</link>
      <sparkle:version>$BUILD_NUMBER</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>https://github.com/$REPO/releases/tag/v$VERSION</sparkle:fullReleaseNotesLink>
      <enclosure url="https://github.com/$REPO/releases/download/v$VERSION/Poppy-$VERSION.dmg" $attributes type="application/octet-stream"/>
    </item>
  </channel>
</rss>
EOF

echo "Built $DMG and $DIST/appcast.xml"
