# Improvements

Known gaps and ideas for the Swift app, roughly in priority order. Remove items as they ship.

## Transcript

- **Copy the transcript.** The live transcript can't be copied: each line is selectable on its own, but not across lines. Add a Copy button (plain text with timestamps and speakers) and make the whole transcript selectable. Milestone 4 adds Markdown export from the meeting page.
- **Filter Whisper's invented lines on near-silence**, e.g. "Thank you." at the end of a recording. Use the segment's confidence (average log probability, compression ratio) rather than blocking phrases people really say.
- **Vocabulary hints.** Pass names and jargon (from the meeting title or calendar) to Whisper as a prompt so they're spelled right.

## Echo

- **Talking over the far end at the echo's loudness.** The default chain (canceller, per-band suppression, gate) leaks no echo into "Me" in replay or live tests, and keeps your words over the far end when you're clearly louder than the echo. When you're about as loud as the echo or quieter, the gate drops them. Gating only while the chain learns (`Stages.gateOnlyWhileLearning`) keeps them word for word, even 9 dB below the echo, but then faint leftover audio becomes stray "Me" words ("Thank you.", "Amen.") about twice per 25 s live. Options: a Whisper hallucination filter good enough to allow that mode, or a setting to choose between the two.
- **Recovery after loud double talk.** The canceller is knocked off course by loud double talk and leaks for a few seconds after, mostly caught by the transcript-level echo filter (`EchoText`). SpeexDSP doesn't expose a way to freeze its adaptation while you talk.
- **Learning latency.** The gate needs about a second of the far end talking before it works, and the canceller a few seconds more to converge. Mic audio is held meanwhile so nothing leaks, which delays the session's first lines by about a second.

## Reliability

- **One live run lost the first 15 s of "Them".** Recording started mid-sentence and the first utterance (cut at the 15 s maximum) produced no lines, with no error logged. It didn't reproduce in later runs or offline. (Lost *final* lines had a separate cause, fixed: stopping didn't wait for the last lines to reach the transcript.) Set `PMA_TRACE_SEGMENTS=1` to print Whisper's segments and scores if it happens again.

## Speakers

- **Tell remote participants apart.** "Them" is everyone on the call. WhisperKit ships SpeakerKit (diarization), which could split it into Speaker 1, Speaker 2, …
