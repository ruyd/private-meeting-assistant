# Improvements

Known gaps and ideas for the Swift app, roughly in priority order. Remove items as they ship.

## Transcript

- **Copy the transcript.** The live transcript can't be copied: each line is selectable on its own, but not across lines. Add a Copy button (plain text with timestamps and speakers) and make the whole transcript selectable. Milestone 4 adds Markdown export from the meeting page.
- **Filter Whisper's invented lines on near-silence**, e.g. "Thank you." at the end of a recording. Use the segment's confidence (average log probability, compression ratio) rather than blocking phrases people really say.
- **Vocabulary hints.** Pass names and jargon (from the meeting title or calendar) to Whisper as a prompt so they're spelled right.

## Echo

- **True echo cancellation before the gate.** The echo gate removes nearly all speaker echo, but with loud speakers (echo near -17 dBFS at the mic) a few fragments still leak as "Me", about one short line per 25 s in testing. A gate also can't keep your voice when it's no louder than the echo. Subtracting the far end with an adaptive filter first (SpeexDSP's MDF echo canceller is BSD-licensed and small; WebRTC AEC3 is stronger but large), then gating what's left, would fix both.
- **Learning latency.** The gate needs about a second of the far end talking before it works. It holds mic audio meanwhile so nothing leaks, which delays the session's first lines by about a second.

## Speakers

- **Tell remote participants apart.** "Them" is everyone on the call. WhisperKit ships SpeakerKit (diarization), which could split it into Speaker 1, Speaker 2, …
