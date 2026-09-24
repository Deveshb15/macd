#!/bin/bash
# Builds a Developer ID–signed release, notarizes it, and produces a stapled DMG.
#
# Requires:
#   DEVELOPMENT_TEAM   your Apple Developer team ID
#   NOTARY_PROFILE     a keychain profile created with:
#                      xcrun notarytool store-credentials <profile> --apple-id … --team-id …
set -euo pipefail

: "${DEVELOPMENT_TEAM:?Set DEVELOPMENT_TEAM to your Apple Developer team ID}"
: "${NOTARY_PROFILE:?Set NOTARY_PROFILE to a notarytool keychain profile}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/build/release"
APP="$BUILD/Build/Products/Release/Macd.app"
DMG="$ROOT/build/macd.dmg"

cd "$ROOT"
[[ -x Vendor/mole/mole ]] || scripts/fetch-mole.sh
xcodegen generate --quiet

xcodebuild -project Macd.xcodeproj -scheme Macd -configuration Release \
    -derivedDataPath "$BUILD" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="Developer ID Application" \
    DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
    OTHER_CODE_SIGN_FLAGS="--timestamp" \
    build

codesign --verify --deep --strict --verbose=2 "$APP"

rm -f "$DMG"
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
cp -R "$APP" "$STAGING/mac'd.app"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "mac'd" -srcfolder "$STAGING" -ov -format UDZO "$DMG"
codesign --sign "Developer ID Application" --timestamp "$DMG"

xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature --verbose "$DMG"
echo "Notarized DMG: $DMG"
