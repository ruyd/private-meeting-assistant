# App Store listing

What to enter in [App Store Connect](https://appstoreconnect.apple.com/apps/6828188643) for version 1.0.0.
Each field is ready to paste; lengths are within Apple's limits. Filled in through the App Store Connect
API on 2026-10-29, except App Privacy and the App Review contact, which the API doesn't cover.

## App Information

| Field | Value |
|---|---|
| Name | Private Meeting Assistant |
| Subtitle (30) | On-device meeting transcripts |
| Primary category | Productivity |
| Secondary category | Business |
| Privacy Policy URL | https://github.com/ruyd/private-meeting-assistant/blob/main/PRIVACY.md |
| Content rights | Doesn't contain, show or access third-party content |

**Age rating**: answer *None* or *No* to every question (no user-generated content shared with others,
no unrestricted web access, no gambling, no contests). The result is 4+.

## App Privacy

**Data Not Collected.** Recordings, transcripts, summaries, notes and voice profiles stay on the Mac.
See `PRIVACY.md`.

## Pricing and Availability

Paid upfront: $9.99 (US; other countries follow Apple's equivalents). Proceeds $8.49.

## Version 1.0.0

| Field | Value |
|---|---|
| Promotional text (170) | Record any call or in-person meeting and get a live transcript, who said what, and a summary with action items. Written on your Mac; nothing is uploaded. |
| Keywords (100) | transcription,transcribe,meeting,notes,minutes,summary,whisper,zoom,teams,meet,recorder,private |
| Support URL | https://github.com/ruyd/private-meeting-assistant/issues |
| Marketing URL | https://github.com/ruyd/private-meeting-assistant |
| Copyright | 2026 Ruy Delgado |
| Build | The one `release-appstore.sh` uploads (1.0.0) |

### Description (4000)

```
Private Meeting Assistant records your meetings and turns them into transcripts, summaries and action items, entirely on your Mac. Nothing you record is uploaded, no bot joins the call, and there's no account to create.

RECORD ANY MEETING
• Zoom, Google Meet, Microsoft Teams, Webex, Slack huddles, FaceTime, or any app that plays sound, plus in-person meetings with just the microphone.
• Your voice from the microphone, everyone else from the call's audio, with echo removed so you can use speakers.
• A mute button keeps you out of the transcript and the recording.

LIVE TRANSCRIPT, ON YOUR MAC
• Words appear as they're spoken, then a more accurate line from Whisper replaces them a few seconds later.
• Runs on your Mac's graphics chip, in many languages. Choose Base or Small (English) or Large (Multi-language).
• Only speech is transcribed: silence, keyboard clicks and fan noise don't turn into made-up lines.

WHO SAID WHAT
• Voices are told apart automatically (Participant 1, 2, 3…). Name them when the recording stops, from a voice clip and a quote.

SUMMARIES AND ACTION ITEMS
• A summary, the decisions made and the action items with their owners, written by Apple Intelligence on your Mac, or by your own Ollama.
• Your typed notes are taken into account.

EVERYTHING IN ONE PLACE
• Each meeting is a folder of plain Markdown files you own: transcript, summary and notes, with the audio, screenshots and video.
• Take screenshots of the meeting app, or record its window as video, cut down to just the call or video if you like. Each lands in the transcript where it happened.
• Play the audio back with the transcript following along; click any line's time to jump there.
• Search every transcript, summary, note and participant at once.

PRIVATE BY DESIGN
Recording, transcription, speaker identification and summaries all happen on your Mac. The only downloads are the speech models, once. The developer collects no data of any kind.

Requires macOS 26 or later. Summaries with Apple Intelligence need a Mac with Apple Intelligence turned on.
```

### Screenshots

1 to 10 images at 16:10: 2880×1800 (or 2560×1600, 1440×900, 1280×800), from demo meetings only. To make
them: record demo meetings with scripted voices into a separate library (the Debug self-test,
`--transcribe-test <seconds> <folder> --muted --speakers --names A,B --title "…"` while `say` or `afplay` plays
the lines), open it with `-demoLibrary <folder> -micMuted YES`, set the window to 1440×900 points, and
capture with `mac/scripts/run-app.sh shot`; save as JPEG (no transparency). The 1.0.0 set, in order:

1. A recording in progress: the live transcript with Participant labels, words appearing.
2. A finished meeting: summary, decisions and action items above the transcript.
3. "Who spoke?": naming the voices from clips and quotes.
4. The meetings list with search.
5. A transcript with a screenshot and a video in it, and the audio player.
6. The New Recording page: sources (apps, system audio, microphone only) and options.

### App Review information

Sign-in required: **No**. Contact: your name, phone and email.

Notes:

```
Private Meeting Assistant records meetings and transcribes them on the Mac. No account is needed.

Permissions: Microphone records the user. System Audio Recording hears the other participants in calls (macOS asks on the first recording). Screen Recording is only used when the user takes a screenshot or records video of the meeting app they picked; nothing is captured otherwise.

First launch: the app downloads a speech model (about 570 MB) from Hugging Face. It is data for the bundled whisper.cpp engine, not code. The voice activity model is bundled; the optional speaker model (8 MB) is also downloaded as data.

Summaries use Apple Intelligence (on in System Settings › Apple Intelligence & Siri) or the user's own Ollama on localhost. No other servers are contacted.

To test without a call: choose "Microphone only" on the New Recording page, press Start recording (⌘R), speak for 20 seconds or so, and press Stop (⌘.). The meeting opens with its transcript, and a summary follows. To test call audio, play a video in any app with "System audio" selected.
```

## Export compliance

Already answered in the build: `ITSAppUsesNonExemptEncryption` is `NO` (the app only uses HTTPS through
Apple's frameworks), so App Store Connect won't ask.
