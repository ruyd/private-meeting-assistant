#!/usr/bin/env bash
# Archives the sandboxed Mac App Store build (the AppStore configuration) and uploads it to App Store
# Connect, where it can go to TestFlight and App Review. The Developer ID DMG is scripts/release.sh.
#
# Signs and uploads with the Apple account signed in to Xcode (Settings › Accounts), which needs the
# Apple Distribution and Mac Installer Distribution certificates on this Mac (APPSTORE.md, "Signing").
# Or with an App Store Connect API key instead, if it's allowed cloud-managed distribution certificates:
#   ASC_KEY_PATH=/path/to/AuthKey_XXXX.p8 ASC_KEY_ID=XXXX ASC_ISSUER_ID=<issuer-uuid> mac/scripts/release-appstore.sh
#
# Xcode creates or updates the App Store provisioning profile it needs (-allowProvisioningUpdates). Each upload needs a new build number: BUILD_NUMBER, or the time.
# EXPORT_ONLY=1 writes the signed .pkg to build/appstore/ instead of uploading (nothing is recorded).
#
# Before building it checks the version is described in CHANGELOG.md and everything is committed
# (scripts/release-common.sh); after uploading it adds the build to CHANGELOG.md and tags the commit.
set -euo pipefail
cd "$(dirname "$0")/.."

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
source scripts/release-common.sh
release_checks
OUT=build/appstore
AUTH=(-allowProvisioningUpdates)
if [[ -n "${ASC_KEY_PATH:-}" ]]; then
  : "${ASC_KEY_ID:?set ASC_KEY_ID with ASC_KEY_PATH}" "${ASC_ISSUER_ID:?set ASC_ISSUER_ID with ASC_KEY_PATH}"
  AUTH+=(-authenticationKeyPath "$ASC_KEY_PATH" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
fi

xcodegen generate
rm -rf "$OUT"
mkdir -p "$OUT"

echo "Archiving build $BUILD_NUMBER…"
xcodebuild -project PrivateMeetingAssistant.xcodeproj -scheme PrivateMeetingAssistant -configuration AppStore \
  -destination 'generic/platform=macOS' -archivePath "$OUT/PrivateMeetingAssistant.xcarchive" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" "${AUTH[@]}" archive | grep -E "error:|warning: .*sign|\*\* ARCHIVE" || true
[[ -d "$OUT/PrivateMeetingAssistant.xcarchive" ]] || { echo "Archive failed." >&2; exit 1; }

OPTIONS=ExportOptions-AppStore.plist
if [[ -n "${EXPORT_ONLY:-}" ]]; then
  OPTIONS="$OUT/ExportOptions.plist"
  plutil -replace destination -string export -o "$OPTIONS" ExportOptions-AppStore.plist
fi
if [[ -n "${EXPORT_ONLY:-}" ]]; then echo "Exporting…"; else echo "Uploading to App Store Connect…"; fi
log=$(xcodebuild -exportArchive -archivePath "$OUT/PrivateMeetingAssistant.xcarchive" -exportOptionsPlist "$OPTIONS" \
  -exportPath "$OUT" "${AUTH[@]}" 2>&1) || true
grep -E "error:|\*\* EXPORT|Upload" <<<"$log" || true
# Stop here unless the package was really exported or uploaded (xcodebuild's messages are the record).
if ! grep -q "EXPORT SUCCEEDED" <<<"$log"; then
  echo "Export failed; nothing was uploaded or recorded. See the errors above (signing: APPSTORE.md)." >&2
  exit 1
fi
if [[ -n "${EXPORT_ONLY:-}" ]]; then
  echo "Done: build $BUILD_NUMBER. The .pkg is in $OUT."
else
  echo "Done: $VERSION ($BUILD_NUMBER). It appears in App Store Connect (TestFlight) after processing, usually within 30 minutes."
  release_record "App Store" appstore
fi
