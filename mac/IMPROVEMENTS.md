# Improvements

Known gaps and ideas for the Swift app, roughly in priority order. Remove items as they ship.

## Transcript

- **Copy the transcript.** The live transcript can't be copied: each line is selectable on its own, but not across lines. Add a Copy button (plain text with timestamps and speakers) and make the whole transcript selectable. Milestone 4 adds Markdown export from the meeting page.
- **Filter Whisper's invented lines on near-silence**, e.g. "Thank you." at the end of a recording. Use the segment's confidence (average log probability, compression ratio) rather than blocking phrases people really say.
- **Vocabulary hints.** Pass names and jargon (from the meeting title or calendar) to Whisper as a prompt so they're spelled right.

## Echo

- **Per-band residual echo suppression for double talk.** SpeexDSP's echo canceller now subtracts the far end (10–13 dB on loud laptop or monitor speakers, which distort in ways a linear filter can't model), and the gate removes what's left: no echo leaked into "Me" in replay or live tests. But when you talk over the far end at about the echo's loudness, the gate still drops much of your voice, because it judges whole 30 ms frames. SpeexDSP's preprocessor suppresses residual echo per frequency band, keeping your voice in the bands where it dominates; adding it (`preprocess.c`, `filterbank.c`) and judging the gate per band is the next step. Measure with the replay test (`EchoReplayTests`, voice injected with `ECHO_REPLAY_NEAR_DB`).
- **Learning latency.** The gate needs about a second of the far end talking before it works, and the canceller a few seconds more to converge. Mic audio is held meanwhile so nothing leaks, which delays the session's first lines by about a second.

## Reliability

- **One live run lost the first 15 s of "Them".** Recording started mid-sentence and the first utterance (cut at the 15 s maximum) produced no lines, with no error logged. It didn't reproduce in three more runs or offline. Set `PMA_TRACE_SEGMENTS=1` to print Whisper's segments and scores if it happens again.

## Speakers

- **Tell remote participants apart.** "Them" is everyone on the call. WhisperKit ships SpeakerKit (diarization), which could split it into Speaker 1, Speaker 2, …
