#!/usr/bin/env bash
# Builds a Developer ID signed, notarized and stapled DMG in build/release/.
#
# One-time setup (stores the App Store Connect API key in your keychain):
#   xcrun notarytool store-credentials pma-notary \
#     --key /path/to/AuthKey_XXXX.p8 --key-id XXXX --issuer <issuer-uuid>
#
# SKIP_NOTARIZE=1 builds and signs the DMG without notarizing (local testing only; nothing is recorded).
#
# Before building it checks the version is described in CHANGELOG.md and everything is committed
# (scripts/release-common.sh); after notarizing it adds the build to CHANGELOG.md and tags the commit.
set -euo pipefail
cd "$(dirname "$0")/.."

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
PROFILE="${NOTARY_PROFILE:-pma-notary}"
IDENTITY="Developer ID Application"
APP_NAME="Private Meeting Assistant"
OUT=build/release
source scripts/release-common.sh
release_checks

notarize() {
  local file=$1 result id status
  echo "Notarizing $(basename "$file")…"
  result=$(xcrun notarytool submit "$file" --keychain-profile "$PROFILE" --wait --output-format json)
  id=$(plutil -extract id raw - <<<"$result")
  status=$(plutil -extract status raw - <<<"$result")
  if [[ "$status" != "Accepted" ]]; then
    echo "Notarization $status. Apple's log:" >&2
    xcrun notarytool log "$id" --keychain-profile "$PROFILE" >&2
    exit 1
  fi
}

rm -rf "$OUT"
mkdir -p "$OUT"

xcodegen generate --quiet
xcodebuild -project PrivateMeetingAssistant.xcodeproj -scheme PrivateMeetingAssistant \
  -configuration Release -archivePath "$OUT/app.xcarchive" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" archive -quiet
xcodebuild -exportArchive -archivePath "$OUT/app.xcarchive" \
  -exportOptionsPlist ExportOptions.plist -exportPath "$OUT" -quiet

APP="$OUT/$APP_NAME.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
DMG="$OUT/PrivateMeetingAssistant-$VERSION.dmg"
codesign --verify --strict --deep "$APP"

if [[ "${SKIP_NOTARIZE:-0}" != 1 ]]; then
  # Staple the app itself too, so it opens offline after being copied out of the DMG.
  ditto -c -k --keepParent "$APP" "$OUT/app.zip"
  notarize "$OUT/app.zip"
  xcrun stapler staple -q "$APP"
fi

mkdir "$OUT/dmg"
ditto "$APP" "$OUT/dmg/$APP_NAME.app"
ln -s /Applications "$OUT/dmg/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$OUT/dmg" -fs HFS+ -format UDZO -ov -quiet "$DMG"
codesign --sign "$IDENTITY" --timestamp "$DMG"

if [[ "${SKIP_NOTARIZE:-0}" != 1 ]]; then
  notarize "$DMG"
  xcrun stapler staple -q "$DMG"
  spctl --assess --type execute -vv "$APP"
  spctl --assess --type open --context context:primary-signature -vv "$DMG"
fi

echo "Built $DMG ($(du -h "$DMG" | cut -f1))"
[[ "${SKIP_NOTARIZE:-0}" == 1 ]] || release_record "Developer ID" devid
