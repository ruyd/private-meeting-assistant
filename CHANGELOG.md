# Changelog

What changed in each version of the macOS app, newest first, and every build that was published. The
version is `MARKETING_VERSION` in `mac/project.yml`.

Before a release: move what's under **Unreleased** into a section for the new version (with the date),
set `MARKETING_VERSION` to match, and commit. The release scripts refuse to build otherwise, and after
a successful release they add the build to **Published builds** and tag the commit; commit that line.

## Unreleased

- The meeting page's transcript is one block of text: select and copy across any number of lines.
- Playing a meeting's audio highlights the line being played and keeps it in view; click a line's time to play from there.
- Transcript text size: A− / A+ in the toolbar (⌘− / ⌘=), on the meeting page and while recording.
- Rename a meeting while recording (its folder follows when the recording stops), and a clearer rename button on the meeting page.
- Notes: type them while recording or afterwards; they're saved in notes.md, searchable, and used for the summary.
- Live transcript: words appear as they're spoken (about half a second, with Apple's on-device recognizer), then Whisper's more accurate line replaces them a few seconds later. The Live / Delayed switch in the recording view turns it off.
- No more "Thank you." over silence or noise: a voice activity model (Silero VAD, built in) checks each stretch of audio for someone talking before Whisper transcribes it, and passes on only the part with speech, so noise just before or after your words isn't written up either (an invented "Gracias." in front of a real line). Live, with a fan above the mic, Whisper got nothing to invent from in 30 seconds of nobody talking, and every spoken sentence came through.
- Fewer invented lines: Whisper's stock phrases over room noise, keyboard clicks and a fan near the mic ("Thank you.", "I'm going to go ahead…") and its repeat loops no longer reach the transcript. With live text on, a line is also dropped when Apple's recognizer, listening to the same audio, heard no words there.
- Summaries no longer make up a meeting: a recording with almost nothing said gets "Too little was said to summarize.", and the model is told to say when little of substance was discussed instead of inventing topics or tasks.
- The microphone's rumble below voices (fans, air conditioning, desk bumps) is filtered out, in the transcript and the saved audio: about 10 dB less noise from a fan above the mic.
- Steady background noise on the microphone (air conditioning, a computer's hum) is turned down by up to 20 dB, in the transcript and the saved audio, also in meetings without system audio.
- Action items no longer show "— Participant N" (or another stand-in) when the model couldn't tell who owns them: an owner must be someone in the meeting, and placeholders in summaries written earlier are hidden.
- Settings › About credits the open-source software and models the app uses (whisper.cpp, the Whisper models, Silero VAD, WeSpeaker, SpeexDSP, GRDB, and Ollama outside the App Store version), each with its license, and shows their full license texts (Licenses…).
- Volume slider in the meeting's audio player, 0 to 200% with 100% in the middle (marked |), 110% to start, remembered. Playback goes through AVAudioEngine with a gain stage, as AVAudioPlayer stops at 100%.
- Saved audio (audio.m4a) is 48 kHz stereo instead of 16 kHz mono: the call and anything shared in it keep their full quality, and so does your microphone when echo removal is off (headphones) or in an in-person meeting. With echo removal on, your voice is still the echo-removed one, which works at 16 kHz. About 50 MB an hour instead of 15.
- A summary shows which engine wrote it ("Written by Apple Intelligence", "… in your Ollama"), and while it's written the meeting says which it's using. It used to say "Writing with" the Ollama model even with Apple Intelligence chosen, so a changed engine looked unchanged.
- Settings › Summaries lists the engines (Automatic, Apple Intelligence, your Ollama, a downloaded Ollama) to pick from directly, each with its state, like the speech models; Automatic says which one it's using. Apple Intelligence used to be only in a dropdown, while its row below just showed its state.
- Settings, "Who spoke?" and the window picker close the same way: a round ✕ at the top right (or Escape), as in Claude. Settings no longer shows the traffic-light buttons, and "Who spoke?" loses its Skip button (the ✕ skips).
- The Large v3 Turbo speech model is now called Large (Multi-language) in Settings, next to Base (English) and Small (English).
- Mute button next to the microphone, on the New Recording page (to start muted) and while recording (⇧⌘M): the mic's audio becomes silence before anything hears it, so nothing you say is transcribed or saved until you unmute. It stays muted across relaunches.
- Screenshots and video capture the right window when the app has several (a browser): the one whose title shows a call or a video (YouTube, Meet, Teams, Zoom, Webex…), else the one you pick from a sheet of the app's windows, then the same one for the rest of the recording. They used to take the largest window, so a focused article could be captured instead of the call.
- On the meeting page, clicking a screenshot's or video's picture opens it; the folder icon next to it shows it in Finder (it was a "Video" or "Screenshot" link, and the picture did nothing).
- Record video (cut size), in the video button's menu: the video keeps the window's full width without the browser's tabs (at most an inch off the top) and the page below the video (found by what changes), re-encoded at 720p, 2.5 Mbit/s. On three YouTube recordings: 59–403 MB down to 3–25 MB, finished in less time than the video ran.
- Videos show as a still with a play button in the transcript (and in the meetings list when there's no screenshot), instead of a small link.
- Videos no longer echo: they used to record the raw microphone, which also hears the call from the speakers. Record video now records the app's sound only; Record video + mic (the button's menu) mixes in your voice from the echo-removed microphone when the video stops.
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
