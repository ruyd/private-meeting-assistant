# Shared by release.sh and release-appstore.sh: the version and build number, checks before building,
# and the record of what was published (CHANGELOG.md's "Published builds" and a git tag).
# Source it from mac/: `source scripts/release-common.sh`.

REPO_ROOT=$(git rev-parse --show-toplevel)
CHANGELOG="$REPO_ROOT/CHANGELOG.md"

# The version people see (MARKETING_VERSION in project.yml) and a build number that always increases.
VERSION=$(sed -nE 's/^ *MARKETING_VERSION: *"?([^"]+)"?.*/\1/p' project.yml | head -1)
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}"

# Fails unless the version can be released: X.Y.Z, described in CHANGELOG.md, everything committed, and
# the build number newer than any published one. ALLOW_DIRTY=1 skips the committed check (local tries).
release_checks() {
  local problems=()
  [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || problems+=("MARKETING_VERSION in project.yml is \"$VERSION\"; use X.Y.Z.")
  grep -qE "^## $VERSION( |$)" "$CHANGELOG" \
    || problems+=("CHANGELOG.md has no \"## $VERSION\" section: move Unreleased into one first.")
  if [[ -z "${ALLOW_DIRTY:-}" && -n "$(git status --porcelain)" ]]; then
    problems+=("There are uncommitted changes; commit them so the build matches a commit (or ALLOW_DIRTY=1 for a local try).")
  fi
  local last
  last=$( (grep -E '^\| [0-9]{4}-' "$CHANGELOG" || true) | awk -F'|' '{gsub(/ /, "", $4); print $4}' | sort -n | tail -1)
  [[ -z "$last" || "$BUILD_NUMBER" -gt "$last" ]] || problems+=("Build $BUILD_NUMBER isn't newer than the last published build, $last.")
  if (( ${#problems[@]} )); then
    printf 'Not releasing:\n' >&2
    printf '  - %s\n' "${problems[@]}" >&2
    exit 1
  fi
  local earlier
  earlier=$(grep -cE "^\| [0-9-]+ \| $VERSION \|" "$CHANGELOG" || true)
  (( earlier > 0 )) && echo "Note: $VERSION already has $earlier published build(s); this adds build $BUILD_NUMBER."
  echo "Releasing $VERSION ($BUILD_NUMBER) from $(git rev-parse --short HEAD)."
}

# Records a published build: a row in CHANGELOG.md's "Published builds" and a tag on the commit.
# $1: the channel's name for the table ("App Store", "Developer ID"); $2: its tag prefix.
release_record() {
  local channel=$1 prefix=$2 commit tag
  commit=$(git rev-parse --short HEAD)
  tag="$prefix/$VERSION-$BUILD_NUMBER"
  printf '| %s | %s | %s | %s | %s |\n' "$(date +%Y-%m-%d)" "$VERSION" "$BUILD_NUMBER" "$channel" "$commit" >> "$CHANGELOG"
  git tag -a "$tag" -m "$channel $VERSION ($BUILD_NUMBER)" HEAD
  echo "Recorded in CHANGELOG.md and tagged $tag. Commit CHANGELOG.md, then push the tag: git push origin $tag"
}
