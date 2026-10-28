# Improvements

Known gaps and ideas for the Swift app, roughly in priority order. Remove items as they ship.

## Transcript

- **Select across transcript lines.** Copy Transcript (Record and meeting pages) and Markdown export cover copying, but a drag-selection still can't span lines: each line is its own text view. A single selectable text block (or an `NSTextView`) would fix it, at some cost for very long meetings.
- **Filter Whisper's invented lines on near-silence**, e.g. "Thank you." at the end of a recording. Use the segment's confidence (average log probability, compression ratio) rather than blocking phrases people really say.
- **Vocabulary hints.** Pass names and jargon (from the meeting title or calendar) to Whisper as a prompt so they're spelled right.

## Echo

- **Talking over the far end at the echo's loudness.** The default chain (canceller, per-band suppression, gate) leaks no echo into "Me" in replay or live tests, and keeps your words over the far end when you're clearly louder than the echo. When you're about as loud as the echo or quieter, the gate drops them. Gating only while the chain learns (`Stages.gateOnlyWhileLearning`) keeps them word for word, even 9 dB below the echo, but then faint leftover audio becomes stray "Me" words ("Thank you.", "Amen.") about twice per 25 s live. A Whisper hallucination filter good enough to make that mode the default would remove the trade-off.
- **Setting: "Keep my voice when I talk over others".** Until then, let people choose: the default (clean transcript, may drop words you say over someone at the echo's loudness) or `gateOnlyWhileLearning` (keeps those words, adds occasional stray words). Useful for people who often talk over others without headphones.
- **Recovery after loud double talk.** The canceller is knocked off course by loud double talk and leaks for a few seconds after, mostly caught by the transcript-level echo filter (`EchoText`). SpeexDSP doesn't expose a way to freeze its adaptation while you talk.
- **Learning latency.** The gate needs about a second of the far end talking before it works, and the canceller a few seconds more to converge. Mic audio is held meanwhile so nothing leaks, which delays the session's first lines by about a second.

## Reliability

- **One live run lost the first 15 s of "Them".** Recording started mid-sentence and the first utterance (cut at the 15 s maximum) produced no lines, with no error logged. It didn't reproduce in later runs or offline. (Lost *final* lines had a separate cause, fixed: stopping didn't wait for the last lines to reach the transcript.) Set `PMA_TRACE_SEGMENTS=1` to print Whisper's segments and scores if it happens again.

## Data

- **Rebuild the index from the meeting folders.** Each meeting is a folder of Markdown files; the database is only the index for the list and search. After reinstalling (or moving folders around), scan the meetings folder and re-index `transcript.md` and `summary.md`. The same would pick up edits made to those files outside the app, which are currently not read back.
- **Screenshots and video in the meeting folder.** The folder layout is ready for them; the capture features don't exist yet.
- **Meetings recorded before folders** (the two from the prototype) get a folder the first time you use Show in Finder on them. A one-time "create folders for all meetings" step would be tidier.

## Speakers

- **Tell remote participants apart.** "Them" is everyone on the call. WhisperKit ships SpeakerKit (diarization), which could split it into Speaker 1, Speaker 2, …
