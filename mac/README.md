# Private Meeting Assistant (macOS, Swift)

Native SwiftUI port of the Tauri prototype in the repository root. Requires macOS 26 and Xcode 26+.

## Develop

The Xcode project is generated from `project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`):

```bash
cd mac
xcodegen generate
open PrivateMeetingAssistant.xcodeproj
```

Transcription uses [whisper.cpp](https://github.com/ggml-org/whisper.cpp) (Metal). `xcodegen generate` first runs `scripts/fetch-whisper.sh`, which downloads the pinned prebuilt framework into `Vendor/whisper.framework` and checks its SHA-256; to update whisper.cpp, change the tag and checksum there.

Every build, Debug included, is signed with the team's **Developer ID Application** certificate and uses Hardened Runtime. A stable signature means macOS keeps the Microphone and System Audio permissions across rebuilds.

## Release

```bash
mac/scripts/release.sh
```

It archives, exports, notarizes and staples the app, then wraps it in a signed and notarized DMG at `mac/build/release/`. Notarization reads an App Store Connect API key stored in the keychain under the profile `pma-notary` (see the comment at the top of the script). `SKIP_NOTARIZE=1` builds a signed DMG without notarizing.
