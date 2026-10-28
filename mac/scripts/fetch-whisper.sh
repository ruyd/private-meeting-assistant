#!/usr/bin/env bash
# Puts whisper.cpp's prebuilt macOS framework (Metal, shaders embedded) in Vendor/whisper.framework.
# Pinned to one release and checked against its SHA-256; runs before `xcodegen generate`.
# To update: change TAG and SHA256 to a newer whisper-<tag>-xcframework.zip from
# https://github.com/ggml-org/whisper.cpp/releases, then delete Vendor/whisper.framework.
set -euo pipefail
cd "$(dirname "$0")/.."

TAG=b5454 # whisper.cpp v1.9.5
SHA256=e57f8c48933000acabc13bb913fbe82805d483a2deff692cc6738836bd92393b
DEST=Vendor/whisper.framework
# Outside the framework: code signing rejects stray files in a bundle.
STAMP="Vendor/.whisper-$TAG"

[[ -f "$STAMP" && -d "$DEST" ]] && exit 0

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
echo "Fetching whisper.cpp $TAG…"
curl -sSL --fail -o "$work/whisper.zip" \
  "https://github.com/ggml-org/whisper.cpp/releases/download/$TAG/whisper-$TAG-xcframework.zip"
echo "$SHA256  $work/whisper.zip" | shasum -a 256 -c --quiet
unzip -q "$work/whisper.zip" -d "$work/x"

rm -rf "$DEST" Vendor/.whisper-*
mkdir -p Vendor
# Only the macOS slice (arm64 and x86_64); symlinks kept as they are in a framework bundle.
ditto "$work/x/build-apple/whisper.xcframework/macos-arm64_x86_64/whisper.framework" "$DEST"
touch "$STAMP"
