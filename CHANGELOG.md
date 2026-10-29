# Changelog

What changed in each version of the macOS app, newest first, and every build that was published. The
version is `MARKETING_VERSION` in `mac/project.yml`.

Before a release: move what's under **Unreleased** into a section for the new version (with the date),
set `MARKETING_VERSION` to match, and commit. The release scripts refuse to build otherwise, and after
a successful release they add the build to **Published builds** and tag the commit; commit that line.

## Unreleased

- Saved audio no longer crackles: small gaps and overlaps between captured chunks (2–9 ms dropouts) are gone.

## 1.0.0 — 2026-10-28

First public release, on the Mac App Store and as a notarized download.

- Live transcription on the Mac with whisper.cpp (Metal): Base, Small or Large v3 Turbo.
- Records your microphone and the call's audio (one app, all system audio, or the microphone only for in-person meetings). No bot joins the meeting.
- Echo removal without headphones, in the transcript and in the saved audio.
- Tells speakers apart (Participant 1, 2…) with an on-device speaker model; name them when the recording stops, from a voice clip, a quote and the calendar's invitees.
- Summaries, decisions and action items, written on the Mac by Apple Intelligence or your own Ollama (the notarized download can also fetch its own Ollama).
- Save the meeting's audio, record the meeting app's window as video, and take screenshots, all placed in the transcript.
- Sign in with Google, Microsoft 365 or Zoom to pick upcoming meetings, name recordings and keep the invitees.
- Meetings are folders of Markdown files you own, with full-text search across transcripts, summaries and participants.
- Inline audio player and copy buttons for transcripts and summaries.

## Published builds

Added by `mac/scripts/release-appstore.sh` and `mac/scripts/release.sh`. Each build is tagged
`<channel>/<version>-<build>` (for example `appstore/1.0.0-202610281530`).

| Date | Version | Build | Channel | Commit |
|---|---|---|---|---|
| 2026-10-28 | 1.0.0 | 202610281803 | App Store | 4427a09 |
