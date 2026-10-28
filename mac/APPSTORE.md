# Selling on the Mac App Store

The app ships two ways from the same code:

| | Developer ID (DMG) | Mac App Store |
|---|---|---|
| Build | `Release` configuration, `scripts/release.sh` | `AppStore` configuration, `scripts/release-appstore.sh` |
| Signing | Developer ID, notarized | Apple Distribution, App Store profile (automatic) |
| Sandbox | No | Yes (`PrivateMeetingAssistant/AppStore.entitlements`) |
| Summaries | Apple Intelligence, your Ollama, or a downloaded Ollama | Apple Intelligence or your Ollama |
| Meetings folder | `~/Meetings` by default | Chosen in an open panel, kept with a security-scoped bookmark |
| Uninstall button | In Settings › About | No (removed from Launchpad or the Applications folder) |

The `APPSTORE` compile flag (set only in the `AppStore` configuration) makes the differences:

- **No downloaded Ollama.** The App Store doesn't allow downloading and running code (guideline 2.5.2), so the code that downloads, verifies and starts Ollama isn't compiled in at all. Summaries use Apple's on-device model (Foundation Models), or the user's own Ollama on `localhost`. Speech and speaker models are still downloaded: they're data, not code.
- **The meetings folder** is one the user picks (`files.user-selected.read-write`), with a bookmark per folder ever chosen, so earlier meetings stay readable after switching folders.
- **No `tccutil`** and no self-uninstall.

Everything else was checked in the sandboxed build: microphone and system-audio capture (Core Audio process tap), live transcription, telling speakers apart, saving audio, writing to the chosen folder, and summaries. It also includes the privacy manifest (`PrivacyInfo.xcprivacy`: UserDefaults, elapsed time, free disk space; nothing tracked or collected) and `ITSAppUsesNonExemptEncryption = NO`.

## One-time setup in App Store Connect

1. **Agreements, Tax, and Banking**: accept the Paid Applications agreement and add bank and tax details. A paid app can't go on sale without them.
2. **Apps › New App**: platform macOS, name "Private Meeting Assistant" (or another if taken), bundle ID `dev.ruy.private-meeting-assistant` (Xcode registers it on the first upload if needed), any SKU.
3. **Pricing and Availability**: choose the price and the countries.
4. **App Privacy**: answer "Data Not Collected". Recordings, transcripts, summaries and voice profiles stay on the Mac; calendar sign-ins go straight from the Mac to Google, Microsoft or Zoom, never to you. Link a privacy policy URL that says the same (required for every app).
5. **App information**: category Productivity, age rating questionnaire, support URL.
6. **Version page**: description, keywords, and screenshots (16:10, e.g. 2880×1800). `docs/images/` has a start; debug builds launched with `-sampleMeetings YES` show made-up meetings for clean screenshots.
7. **App Review notes**, so review goes smoothly. Something like:
   > Records meetings and transcribes them on the Mac. Microphone: records the user. System Audio Recording: hears the other participants in calls (macOS asks). Screen Recording: only for screenshots and video of the meeting app the user picks; nothing is captured otherwise. The first launch downloads a speech model (about 570 MB) from Hugging Face; it's data for whisper.cpp, not code. Summaries use Apple Intelligence (turn it on in System Settings) or the user's own Ollama. To test without a call, choose "Microphone only", press ⌘R, speak, and press ⌘. to stop.

## Each release

Create an App Store Connect API key with the App Manager role (Users and Access › Integrations), then:

```bash
ASC_KEY_PATH=~/keys/AuthKey_XXXX.p8 ASC_KEY_ID=XXXX ASC_ISSUER_ID=<issuer-uuid> mac/scripts/release-appstore.sh
```

It archives the `AppStore` configuration with a new build number (the time, or `BUILD_NUMBER`), signs it for the App Store (Xcode creates the Apple Distribution certificate and profile the first time), and uploads it. After processing it shows up in TestFlight; test it there, then add it to the version and submit for review. Bump `MARKETING_VERSION` in `project.yml` for each new version.

`EXPORT_ONLY=1` writes the signed `.pkg` to `mac/build/appstore/` instead of uploading.

The calendar sign-in (Google, Microsoft, Zoom) only appears if `Config/OAuth.local.xcconfig` has client IDs when building (see `OAUTH.md`).

## Testing the sandboxed build locally

```bash
cd mac
xcodebuild -project PrivateMeetingAssistant.xcodeproj -scheme PrivateMeetingAssistant -configuration AppStore \
  -derivedDataPath build/appstore-dd CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="Developer ID Application" DEVELOPMENT_TEAM=7X36HVTXYB build
open "build/appstore-dd/Build/Products/AppStore/Private Meeting Assistant.app"
```

Signing with Developer ID works locally because the sandbox entitlements need no provisioning profile. The sandboxed app keeps its data in `~/Library/Containers/dev.ruy.private-meeting-assistant/`, separate from the Developer ID build's, so it starts with setup and its own speech model download. Meetings recorded with the Developer ID build don't appear in it.
