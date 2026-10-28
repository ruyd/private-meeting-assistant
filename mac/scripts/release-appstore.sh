#!/usr/bin/env bash
# Archives the sandboxed Mac App Store build (the AppStore configuration) and uploads it to App Store
# Connect, where it can go to TestFlight and App Review. The Developer ID DMG is scripts/release.sh.
#
# Needs an App Store Connect API key with the App Manager role (App Store Connect › Users and Access ›
# Integrations), the same kind notarization uses:
#   ASC_KEY_PATH=/path/to/AuthKey_XXXX.p8 ASC_KEY_ID=XXXX ASC_ISSUER_ID=<issuer-uuid> mac/scripts/release-appstore.sh
#
# Xcode creates or updates the Apple Distribution certificate and App Store provisioning profile it
# needs (-allowProvisioningUpdates). Each upload needs a new build number: BUILD_NUMBER, or the time.
# EXPORT_ONLY=1 writes the signed .pkg to build/appstore/ instead of uploading (nothing is recorded).
#
# Before building it checks the version is described in CHANGELOG.md and everything is committed
# (scripts/release-common.sh); after uploading it adds the build to CHANGELOG.md and tags the commit.
set -euo pipefail
cd "$(dirname "$0")/.."

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
source scripts/release-common.sh
release_checks
: "${ASC_KEY_PATH:?set ASC_KEY_PATH to the App Store Connect API key (.p8)}"
: "${ASC_KEY_ID:?set ASC_KEY_ID}"
: "${ASC_ISSUER_ID:?set ASC_ISSUER_ID}"
OUT=build/appstore
AUTH=(-allowProvisioningUpdates -authenticationKeyPath "$ASC_KEY_PATH" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")

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
xcodebuild -exportArchive -archivePath "$OUT/PrivateMeetingAssistant.xcarchive" -exportOptionsPlist "$OPTIONS" \
  -exportPath "$OUT" "${AUTH[@]}" | grep -E "error:|\*\* EXPORT|Upload" || true
if [[ -n "${EXPORT_ONLY:-}" ]]; then
  echo "Done: build $BUILD_NUMBER. The .pkg is in $OUT."
else
  echo "Done: $VERSION ($BUILD_NUMBER). It appears in App Store Connect (TestFlight) after processing, usually within 30 minutes."
  release_record "App Store" appstore
fi
