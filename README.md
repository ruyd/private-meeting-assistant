# Private Meeting Assistant

A macOS desktop app that transcribes your meetings live, then writes the summary and action items into a searchable archive. Everything runs on your Mac.

- **Works with any call app** (Zoom, Meet, Teams, FaceTime, in person). It records your microphone (**Me**) and the Mac's audio output (**Them**), so no bot joins the meeting.
- **Live transcription** with [whisper.cpp](https://github.com/ggerganov/whisper.cpp), using Metal on Apple Silicon.
- **Summaries, decisions and action items** come from a local model running in [Ollama](https://ollama.com).
- **Searchable archive** in SQLite with FTS5. Search covers transcripts, summaries and titles, and you can export any meeting to Markdown.
- **Nothing leaves the machine.** The only network traffic is a one-time download of the speech model from Hugging Face, plus requests to Ollama on `localhost`.

## Requirements

- macOS 13+ (Apple Silicon recommended)
- [Rust](https://rustup.rs), Node 20+, CMake, and the Xcode Command Line Tools
- [Ollama](https://ollama.com) with at least one model pulled, e.g. `ollama pull gemma4:12b`

## Run

```bash
npm install
npm run tauri dev
```

On first launch, open **Settings** and download a Whisper model (`base.en` is a good start). macOS will ask for **Microphone** and **Screen & System Audio Recording** permission the first time you record. When you run it in development, the permission is granted to your terminal app instead.

Build a standalone `.app` / `.dmg`:

```bash
npm run tauri build
```

## Tests

```bash
cd src-tauri
cargo test                                  # unit tests: DB/search, resampler, VAD, export, parsing
cargo test --release -- --ignored --nocapture   # end-to-end: real Whisper model + local Ollama
```

The end-to-end tests need the `base.en` model downloaded (through the app or Settings) and Ollama running with the configured summary model.

## How it works

```
mic (cpal) ─────┐                       ┌─> Whisper worker ─> SQLite (+FTS5) ─> UI "segment" events
                ├─> resample to 16 kHz ─> per-source VAD ─┘
system (SCK) ───┘                       (utterances, ≤15 s)
stop ─> flush ─> Ollama summary (map-reduce for long meetings) ─> stored JSON + search index
```

| Path | What it does |
|---|---|
| `src-tauri/src/audio/` | Mic capture (cpal), system audio (ScreenCaptureKit), streaming windowed-sinc resampler |
| `src-tauri/src/transcribe/` | Energy VAD segmenter, Whisper worker thread, model download |
| `src-tauri/src/recorder.rs` | Recording session: wires capture → VAD → Whisper → DB/events, optional WAV |
| `src-tauri/src/llm/ollama.rs` | Summary / decisions / action items via Ollama structured output |
| `src-tauri/src/db/` | SQLite schema, full-text search |
| `src/` | React UI: Record, Meetings (search), Meeting detail, Settings |

Data (database, models, optional audio) lives in `~/Library/Application Support/dev.ruy.private-meeting-assistant/`.

## Known limitations

- Speakers are split into **Me** and **Them** by audio source. Several remote participants all show up as "Them".
- Without headphones, your speakers leak into the mic, so remote speech can also be transcribed as "Me".
