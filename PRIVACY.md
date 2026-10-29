# Privacy Policy

*Private Meeting Assistant for macOS. Last updated October 29, 2026.*

Private Meeting Assistant records and transcribes meetings on your Mac. It is built so that what you
record never leaves it.

## What the app collects

Nothing. The developer receives no data from the app: no recordings, transcripts, summaries, notes,
voice profiles, usage analytics, crash reports or identifiers. There are no accounts, no tracking and no
advertising.

## What stays on your Mac

- **Recordings and everything made from them**: audio, video, screenshots, transcripts, summaries, notes
  and the voice profiles used to tell speakers apart are saved in the meetings folder you choose, and in
  the app's own storage on your Mac. Transcription, speaker identification and summaries all run on your
  Mac (with Apple Intelligence, or an Ollama you run yourself).
- **Settings** are kept in the app's preferences on your Mac.

You can delete any meeting from the app, or its folder in Finder.

## Network connections the app makes

- **Model downloads**: the speech and speaker models are downloaded once from Hugging Face
  (huggingface.co). These are plain file downloads; nothing about you or your meetings is sent.
- **Calendar and meeting sign-in (optional)**: if you sign in with Google, Microsoft 365 or Zoom, the
  app talks directly from your Mac to that service to list your upcoming meetings and their invitees.
  The sign-in tokens are kept in your Mac's Keychain. Nothing goes through the developer.
- **Your own Ollama (optional)**: if you choose it for summaries, the app sends the transcript to the
  Ollama server on your own Mac (localhost).

## Permissions

- **Microphone**: to record and transcribe what you say.
- **System audio recording**: to transcribe the other participants in your calls.
- **Screen recording**: only for screenshots and video of the meeting app you pick, when you ask for
  them.

## Children

The app is not directed at children and collects no information from anyone.

## Changes

If this policy changes, the new version will be posted at this address with a new date.

## Contact

Questions: open an issue at https://github.com/ruyd/private-meeting-assistant/issues.
