#!/usr/bin/env bash
# Publishes the DMG that release.sh built as a GitHub release, which the app's updater then offers to
# everyone on the GitHub download. Run it after release.sh, from a clean checkout whose commit is pushed.
#
#   mac/scripts/release.sh && mac/scripts/publish-github.sh
#
# The release is tagged vX.Y.Z on the commit the DMG was built from, titled with the version, and its
# notes are that version's section of CHANGELOG.md. DRAFT=1 creates it as a draft (the updater ignores
# drafts until you publish it on GitHub).
set -euo pipefail
cd "$(dirname "$0")/.."

source scripts/release-common.sh
REPO=ruyd/private-meeting-assistant
APP_NAME="Private Meeting Assistant"
OUT=build/release
DMG="$OUT/PrivateMeetingAssistant-$VERSION.dmg"
APP="$OUT/$APP_NAME.app"
TAG="v$VERSION"

problems=()
[[ -f "$DMG" ]] || problems+=("No $DMG: run scripts/release.sh first.")
if [[ -d "$APP" ]]; then
  built=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
  [[ "$built" == "$VERSION" ]] || problems+=("$APP is $built, but project.yml says $VERSION.")
  archs=$(lipo -archs "$APP/Contents/MacOS/$APP_NAME")
  [[ "$archs" == arm64 ]] || problems+=("The app is built for \"$archs\"; the GitHub download is Apple Silicon only (arm64).")
fi
[[ -f "$DMG" ]] && { xcrun stapler validate -q "$DMG" 2>/dev/null || problems+=("$DMG isn't notarized (built with SKIP_NOTARIZE=1?)."); }
commit=$(git rev-parse HEAD)
[[ -n "$(git branch -r --contains "$commit" 2>/dev/null)" ]] || problems+=("Commit $(git rev-parse --short HEAD) isn't pushed: push it first.")
gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1 && problems+=("GitHub already has a $TAG release.")
if (( ${#problems[@]} )); then
  printf 'Not publishing:\n' >&2
  printf '  - %s\n' "${problems[@]}" >&2
  exit 1
fi

# The version's section of CHANGELOG.md, without its heading.
notes=$(mktemp)
trap 'rm -f "$notes"' EXIT
awk -v v="$VERSION" '
  $0 ~ "^## " v "( |$)" { on = 1; next }
  on && /^## / { exit }
  on { print }
' "$CHANGELOG" > "$notes"
printf '\n---\nFor Macs with Apple Silicon, macOS 26 or later. Open the DMG and drag the app to Applications; it updates itself from then on.\n' >> "$notes"

shasum -a 256 "$DMG" | sed "s|  .*/|  |" > "$DMG.sha256"
gh release create "$TAG" "$DMG" "$DMG.sha256" --repo "$REPO" --target "$commit" \
  --title "$APP_NAME $VERSION" --notes-file "$notes" ${DRAFT:+--draft}
echo "Published $TAG: https://github.com/$REPO/releases/tag/$TAG"
