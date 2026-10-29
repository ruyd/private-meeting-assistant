# Improvements

Known gaps and ideas for the Swift app, roughly in priority order. Remove items as they ship.

## Transcript

- **Select across lines while recording.** The meeting page's transcript is one text view (select and copy across lines), but the live view keeps the design's conversation layout, one view per line; Copy Transcript covers it meanwhile. A text view with the avatars drawn in the margin would bring both together.
- **Play from any word.** Clicking a line's time plays from there; clicking inside a line could too, but would clash with selecting text. Whisper's word timings would allow highlighting the word being played, not just the line.
- **Wind on the mic.** A fan blowing on the mic makes gusts, not a steady hum: -41 to -57 dBFS from one second to the next, mostly 100–150 Hz. The low-cut filter takes what's below 100 Hz and the noise suppressor only learns steady noise, so the gusts stay (in the saved audio; the live recognizer's check keeps them out of the transcript). Options: a higher low-cut (150–200 Hz, thinning low voices), or Apple's voice processing (Voice Isolation), which handles gusts but adjusts the mic's level by itself. Through AVAudioEngine it didn't run here: with a 6-channel default output (QBQ90S) the mic gave silence (7-channel input format) or the engine failed to start (-10875), also with the engine's output set to the built-in speakers. It would need AUVoiceProcessingIO set up directly. (The transcript is safe either way: the voice activity model keeps gusts away from Whisper.)
- **Retune invented-line filtering on more recordings.** Three layers now: the voice activity model (Silero) skips stretches with nobody talking (on the recordings so far: noise scored at most 0.38, speech 0.97 or more, against a 0.5 cut), Whisper's no-speech score (0.3), and, with live text on, lines Apple's recognizer heard no words in. Replay new recordings with `InventedLinesReplay` (`TEST_RUNNER_SILERO_MODEL` shows Silero's scores) to check them.
- **Vocabulary hints.** Pass names and jargon (from the meeting title or calendar) to Whisper as a prompt so they're spelled right.

## Echo

- **Talking over the far end at the echo's loudness.** The default chain (canceller, per-band suppression, gate) leaks no echo into "Me" in replay or live tests, and keeps your words over the far end when you're clearly louder than the echo. When you're about as loud as the echo or quieter, the gate drops them. Gating only while the chain learns (`Stages.gateOnlyWhileLearning`) keeps them word for word, even 9 dB below the echo, but then faint leftover audio becomes stray "Me" words ("Thank you.", "Amen.") about twice per 25 s live. The stricter no-speech cut-off (0.3) may now catch those: worth retrying that mode live.
- **Setting: "Keep my voice when I talk over others".** Until then, let people choose: the default (clean transcript, may drop words you say over someone at the echo's loudness) or `gateOnlyWhileLearning` (keeps those words, adds occasional stray words). Useful for people who often talk over others without headphones.
- **Recovery after loud double talk.** The canceller is knocked off course by loud double talk and leaks for a few seconds after, mostly caught by the transcript-level echo filter (`EchoText`). SpeexDSP doesn't expose a way to freeze its adaptation while you talk.
- **Learning latency.** The gate needs about a second of the far end talking before it works, and the canceller a few seconds more to converge. Mic audio is held meanwhile so nothing leaks, which delays the session's first lines by about a second.

## Reliability

- **One live run lost the first 15 s of "Them".** Recording started mid-sentence and the first utterance (cut at the 15 s maximum) produced no lines, with no error logged. It didn't reproduce in later runs or offline. (Lost *final* lines had a separate cause, fixed: stopping didn't wait for the last lines to reach the transcript.) Set `PMA_TRACE_SEGMENTS=1` to print Whisper's segments and scores if it happens again.

## Data

- **Read notes.md back.** Notes typed in the app are saved to notes.md and the index; edits made to notes.md in another app aren't read back yet (the same gap as transcripts and summaries, below).
- **Rebuild the index from the meeting folders.** Each meeting is a folder of Markdown files; the database is only the index for the list and search. After reinstalling (or moving folders around), scan the meetings folder and re-index `transcript.md` and `summary.md`. The same would pick up edits made to those files outside the app, which are currently not read back.
- **Screenshots and video in the meeting folder.** The folder layout is ready for them; the capture features don't exist yet.

## Summaries

- **Action item owners.** The model sometimes assigns "Me" to a task the other side took on or asked for (e.g. "call back on Monday", said by Them). The prompt could spell out that "Me" is only for things the recorder committed to.
- **More model choices.** Settings offers to download only the recommended model (gemma4:12b, or gemma3:4b under 16 GB); other Ollama models can be picked once installed. A short list of tested models with sizes would help.
- **Stop the downloaded Ollama when idle.** It starts on demand and stops when the app quits; stopping it a few minutes after the last summary would free memory sooner.

## Speakers

- **Tell remote participants apart.** "Them" is everyone on the call. A diarization model (for example pyannote's, run locally) could split it into Speaker 1, Speaker 2, …
