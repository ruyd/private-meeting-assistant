//! A recording session: audio captures feed one pipeline thread that segments
//! each source into utterances and queues them for Whisper. Transcribed text
//! is stored and pushed to the UI as it arrives.

use std::collections::HashMap;
use std::fs::File;
use std::io::BufWriter;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use anyhow::{anyhow, Result};
use crossbeam_channel::{unbounded, Receiver, RecvTimeoutError};
use serde::Serialize;
use tauri::{AppHandle, Emitter};

use crate::audio::{self, AudioChunk, Capture, Source, TARGET_RATE};
use crate::db::Db;
use crate::transcribe::vad::{Segmenter, Utterance};
use crate::transcribe::whisper::Transcriber;

pub struct Session {
    pub meeting_id: i64,
    captures: Vec<Box<dyn Capture>>,
    stop: Arc<AtomicBool>,
    pipeline: Option<JoinHandle<()>>,
    transcriber: Arc<Transcriber>,
}

#[derive(Clone, Serialize)]
struct Levels {
    me: f32,
    them: f32,
}

pub struct StartOptions {
    pub meeting_id: i64,
    pub capture_system_audio: bool,
    pub language: Option<String>,
    pub audio_dir: Option<PathBuf>,
}

/// Starts capturing. Returns the session plus non-fatal warnings (e.g. no
/// system-audio permission — the microphone alone still works).
pub fn start(
    app: AppHandle,
    db: Db,
    transcriber: Arc<Transcriber>,
    opts: StartOptions,
) -> Result<(Session, Vec<String>)> {
    let (tx, rx) = unbounded::<AudioChunk>();
    let mut captures: Vec<Box<dyn Capture>> = Vec::new();
    let mut warnings = Vec::new();

    match audio::mic::start(tx.clone()) {
        Ok(c) => captures.push(c),
        Err(e) => warnings.push(format!("Microphone unavailable: {e}")),
    }
    #[cfg(target_os = "macos")]
    if opts.capture_system_audio {
        match audio::system::start(tx.clone()) {
            Ok(c) => captures.push(c),
            Err(e) => warnings.push(format!("System audio unavailable: {e}")),
        }
    }
    drop(tx);
    if captures.is_empty() {
        return Err(anyhow!(warnings.join("\n")));
    }

    let meeting_id = opts.meeting_id;
    let stop = Arc::new(AtomicBool::new(false));
    let pipeline = {
        let stop = stop.clone();
        let transcriber = transcriber.clone();
        std::thread::Builder::new()
            .name("audio-pipeline".into())
            .spawn(move || pipeline(rx, stop, app, db, transcriber, opts))?
    };

    let session = Session { meeting_id, captures, stop, pipeline: Some(pipeline), transcriber };
    Ok((session, warnings))
}

impl Session {
    /// Stops capture and blocks until every captured utterance is transcribed.
    pub fn finish(mut self) {
        for c in self.captures.drain(..) {
            c.stop();
        }
        self.stop.store(true, Ordering::SeqCst);
        if let Some(p) = self.pipeline.take() {
            let _ = p.join();
        }
        self.transcriber.wait_idle();
    }
}

type Wav = hound::WavWriter<BufWriter<File>>;

fn pipeline(
    rx: Receiver<AudioChunk>,
    stop: Arc<AtomicBool>,
    app: AppHandle,
    db: Db,
    transcriber: Arc<Transcriber>,
    opts: StartOptions,
) {
    let mut segmenters: HashMap<Source, Segmenter> = HashMap::new();
    let mut writers: HashMap<Source, Wav> = HashMap::new();
    let mut levels = Levels { me: 0.0, them: 0.0 };
    let mut last_levels = Instant::now();

    let submit = |source: Source, utt: Utterance| {
        let (start_ms, end_ms) = (utt.start_ms(), utt.end_ms());
        let db = db.clone();
        let app = app.clone();
        let meeting_id = opts.meeting_id;
        transcriber.submit(
            utt.samples,
            opts.language.clone(),
            Box::new(move |text| {
                match db.insert_segment(meeting_id, source.speaker(), start_ms, end_ms, &text) {
                    Ok(seg) => {
                        let _ = app.emit("segment", &seg);
                    }
                    Err(e) => eprintln!("saving segment: {e}"),
                }
            }),
        );
    };

    loop {
        let chunk = match rx.recv_timeout(Duration::from_millis(100)) {
            Ok(c) => Some(c),
            Err(RecvTimeoutError::Timeout) => None,
            Err(RecvTimeoutError::Disconnected) => break,
        };
        if let Some(AudioChunk { source, samples }) = chunk {
            if let Some(dir) = &opts.audio_dir {
                if !writers.contains_key(&source) {
                    match open_wav(dir, source) {
                        Ok(w) => {
                            writers.insert(source, w);
                        }
                        Err(e) => eprintln!("opening audio file: {e}"),
                    }
                }
                if let Some(w) = writers.get_mut(&source) {
                    for &s in &samples {
                        let _ = w.write_sample((s.clamp(-1.0, 1.0) * i16::MAX as f32) as i16);
                    }
                }
            }

            let rms = (samples.iter().map(|s| s * s).sum::<f32>() / samples.len().max(1) as f32).sqrt();
            let level = match source {
                Source::Mic => &mut levels.me,
                Source::System => &mut levels.them,
            };
            *level = level.max(rms);

            for utt in segmenters.entry(source).or_default().push(&samples) {
                submit(source, utt);
            }
        } else if stop.load(Ordering::SeqCst) && rx.is_empty() {
            break;
        }

        if last_levels.elapsed() >= Duration::from_millis(100) {
            let _ = app.emit("levels", levels.clone());
            levels = Levels { me: 0.0, them: 0.0 };
            last_levels = Instant::now();
        }
    }

    for (source, mut seg) in segmenters {
        if let Some(utt) = seg.flush() {
            submit(source, utt);
        }
    }
    for (_, w) in writers {
        if let Err(e) = w.finalize() {
            eprintln!("finalizing audio file: {e}");
        }
    }
}

fn open_wav(dir: &std::path::Path, source: Source) -> Result<Wav> {
    std::fs::create_dir_all(dir)?;
    let spec = hound::WavSpec {
        channels: 1,
        sample_rate: TARGET_RATE,
        bits_per_sample: 16,
        sample_format: hound::SampleFormat::Int,
    };
    Ok(hound::WavWriter::create(dir.join(format!("{}.wav", source.file_stem())), spec)?)
}
