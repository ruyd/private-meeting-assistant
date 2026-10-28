---
name: run-app
description: Build, launch, drive and screenshot the Private Meeting Assistant macOS app (Debug) to see a UI change working. Use when asked to run, start or screenshot the app, or to check a change in the real app rather than in tests.
---

# Run the macOS app

Everything goes through `mac/scripts/run-app.sh` (run from the repo root). It finds Xcode even when
`xcode-select` points at the Command Line Tools, so don't set `DEVELOPER_DIR` yourself.

```bash
mac/scripts/run-app.sh build                       # xcodegen + Debug build; prints errors and BUILD SUCCEEDED/FAILED
mac/scripts/run-app.sh launch                      # quits any running copy, launches with sample meetings, prints windows
mac/scripts/run-app.sh shot <scratchpad>/main.png  # screenshot of the main window
mac/scripts/run-app.sh settings Accounts           # open Settings on a tab: Transcription, Summaries, Accounts, Storage, Permissions, About
mac/scripts/run-app.sh shot <scratchpad>/settings.png Accounts   # screenshot a window by title substring
mac/scripts/run-app.sh windows                     # "<id> <title>" per window
mac/scripts/run-app.sh quit
```

Then **Read the PNG and look at it**: a blank or missing window means the launch failed.

## Claude desktop Run button

`.claude/launch.json` runs `mac/scripts/preview-server.py` on port 8765: it builds and launches the
app, and serves a page that mirrors the app's windows every second. Stopping the preview quits the
app. The mirror needs Screen Recording permission for Claude.app; without it the page says so and
the app still runs in its own window.

## Notes

- Save screenshots in the session's scratchpad directory, not the repo.
- `launch` passes `-sampleMeetings YES`: the meeting list shows made-up meetings (never saved), so
  screenshots don't expose the user's real meetings. Extra args go to the app, e.g.
  `launch -sampleMeetings NO` for real data, or the Debug self-tests `--capture-test`,
  `--transcribe-test` (see `mac/PrivateMeetingAssistant/Debug/CaptureSelfTest.swift`).
- The main window's title is the page shown ("New Recording", or a meeting's title); Settings' title
  is the selected tab.
- Clicking elsewhere in the UI: use AppleScript through System Events, as `settings` does, e.g.
  `osascript -e 'tell application "System Events" to tell (first process whose name is "Private Meeting Assistant") to click button "Refresh" of window 1'`.
  For anything deeper, use computer use.
- Screenshots need Screen Recording permission, and `settings`/clicks need Accessibility permission,
  for the app running the commands. If `shot` fails with an empty capture or `osascript` errors with
  "not allowed assistive access", ask the user to grant it in System Settings › Privacy & Security.
- The app is signed with the Developer ID set in `mac/project.yml`; the build fails without that
  certificate in the keychain.
- Starting a real recording needs microphone and system-audio permission and a downloaded speech
  model; don't start one unless the task needs it.
- Unit tests are separate:
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project mac/PrivateMeetingAssistant.xcodeproj -scheme PrivateMeetingAssistant -destination 'platform=macOS' test`
