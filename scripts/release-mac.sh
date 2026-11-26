#!/usr/bin/env bash
# Build, sign (Developer ID, hardened runtime, inside-out), notarize, staple and package
# Silicon Mode.app as a DMG.
#
#   scripts/release-mac.sh            # full release → dist/SiliconMode-<version>.dmg
#   SKIP_NOTARIZE=1 scripts/release-mac.sh   # signed but not notarized (local testing)
#
# Requires: Xcode 27, xcodegen, the "Developer ID Application: … (LTBSK59BJ2)" identity in the
# login keychain and the notarytool keychain profile "peek-notary" (shared team profile; never
# re-create it here).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MAC="$ROOT/apps/mac"
DIST="$ROOT/dist"
BUILD="$MAC/build/release"
NOTARY_PROFILE="${NOTARY_PROFILE:-peek-notary}"
TEAM="LTBSK59BJ2"

IDENTITY="$(security find-identity -v -p codesigning | awk -F'"' "/Developer ID Application: .*\\($TEAM\\)/ {print \$2; exit}")"
if [[ -z "$IDENTITY" ]]; then
  echo "No Developer ID Application identity for team $TEAM" >&2
  exit 1
fi
echo "Signing as: $IDENTITY"

mkdir -p "$DIST"
cd "$MAC"
xcodegen generate -q
xcodebuild -project SiliconMode.xcodeproj -scheme SiliconMode -configuration Release \
  -derivedDataPath "$BUILD" ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$IDENTITY" DEVELOPMENT_TEAM="$TEAM" \
  PROVISIONING_PROFILE_SPECIFIER= build | grep -E "error:|warning: .*deprecated|BUILD (SUCC|FAIL)" || true

APP="$BUILD/Build/Products/Release/Silicon Mode.app"
[[ -d "$APP" ]] || { echo "Build failed: $APP missing" >&2; exit 1; }
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"

# Sign inside-out with secure timestamps (notarization rejects --timestamp=none).
codesign --force --options runtime --timestamp -i ai.tos.mode.hook -s "$IDENTITY" \
  "$APP/Contents/Helpers/silicon-mode-hook"
codesign --force --options runtime --timestamp \
  --entitlements "$MAC/App/Resources/SiliconMode.entitlements" -s "$IDENTITY" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

if [[ "${SKIP_NOTARIZE:-0}" != "1" ]]; then
  ZIP="$DIST/SiliconMode-$VERSION-notarize.zip"
  ditto -c -k --keepParent "$APP" "$ZIP"
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
  rm -f "$ZIP"
fi

# DMG with an /Applications drop target.
STAGE="$(mktemp -d)"
ditto "$APP" "$STAGE/Silicon Mode.app"
ln -s /Applications "$STAGE/Applications"
DMG="$DIST/SiliconMode-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "Silicon Mode" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
codesign --force --timestamp -s "$IDENTITY" "$DMG"

if [[ "${SKIP_NOTARIZE:-0}" != "1" ]]; then
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
  spctl -a -vvv -t open --context context:primary-signature "$DMG" || true
fi
spctl -a -vvv -t exec "$APP" || true

( cd "$DIST" && shasum -a 256 "$(basename "$DMG")" > SHA256SUMS )
echo "Done: $DMG"
