//! Whisper transcription worker. One background thread owns the model and
//! processes utterances in arrival order from every audio source.

use std::path::Path;
use std::thread::JoinHandle;

use anyhow::{anyhow, Result};
use crossbeam_channel::{unbounded, Sender};
use whisper_rs::{FullParams, SamplingStrategy, WhisperContext, WhisperContextParameters};

use crate::audio::TARGET_RATE;

/// Segments Whisper thinks are probably not speech are dropped.
const NO_SPEECH_THRESHOLD: f32 = 0.6;

pub type OnText = Box<dyn FnOnce(String) + Send>;

enum Job {
    Transcribe { samples: Vec<f32>, language: Option<String>, on_text: OnText },
    /// Replies once every job queued before it has finished.
    Barrier(Sender<()>),
}

pub struct Transcriber {
    tx: Option<Sender<Job>>,
    thread: Option<JoinHandle<()>>,
}

impl Transcriber {
    pub fn load(model_path: &Path) -> Result<Self> {
        // Routes whisper.cpp/ggml logging through whisper-rs, which drops it (no log backend enabled).
        whisper_rs::install_logging_hooks();
        let path = model_path
            .to_str()
            .ok_or_else(|| anyhow!("model path is not valid UTF-8"))?;
        let ctx = WhisperContext::new_with_params(path, WhisperContextParameters::default())
            .map_err(|e| anyhow!("loading Whisper model {path}: {e}"))?;
        let (tx, rx) = unbounded::<Job>();

        let thread = std::thread::Builder::new()
            .name("whisper".into())
            .spawn(move || {
                let mut state = match ctx.create_state() {
                    Ok(s) => s,
                    Err(e) => {
                        eprintln!("whisper: creating state failed: {e}");
                        return;
                    }
                };
                let threads = std::thread::available_parallelism()
                    .map(|n| n.get().min(8) as i32)
                    .unwrap_or(4);
                for job in rx {
                    match job {
                        Job::Barrier(reply) => {
                            let _ = reply.send(());
                        }
                        Job::Transcribe { samples, language, on_text } => {
                            match run(&mut state, &samples, language.as_deref(), threads) {
                                Ok(text) if !text.is_empty() => on_text(text),
                                Ok(_) => {}
                                Err(e) => eprintln!("whisper: {e}"),
                            }
                        }
                    }
                }
            })?;

        Ok(Self { tx: Some(tx), thread: Some(thread) })
    }

    pub fn submit(&self, samples: Vec<f32>, language: Option<String>, on_text: OnText) {
        if let Some(tx) = &self.tx {
            let _ = tx.send(Job::Transcribe { samples, language, on_text });
        }
    }

    /// Blocks until all previously submitted audio has been transcribed.
    pub fn wait_idle(&self) {
        let (reply_tx, reply_rx) = crossbeam_channel::bounded(1);
        if let Some(tx) = &self.tx {
            if tx.send(Job::Barrier(reply_tx)).is_ok() {
                let _ = reply_rx.recv();
            }
        }
    }
}

impl Drop for Transcriber {
    fn drop(&mut self) {
        self.tx.take();
        if let Some(t) = self.thread.take() {
            let _ = t.join();
        }
    }
}

fn run(
    state: &mut whisper_rs::WhisperState,
    samples: &[f32],
    language: Option<&str>,
    threads: i32,
) -> Result<String> {
    let mut params = FullParams::new(SamplingStrategy::Greedy { best_of: 1 });
    params.set_n_threads(threads);
    params.set_language(language);
    params.set_no_context(true);
    params.set_suppress_blank(true);
    params.set_suppress_nst(true);
    params.set_no_speech_thold(NO_SPEECH_THRESHOLD);
    params.set_print_special(false);
    params.set_print_progress(false);
    params.set_print_realtime(false);
    params.set_print_timestamps(false);

    // whisper.cpp rejects inputs shorter than one second; pad with silence.
    let min_len = TARGET_RATE as usize * 11 / 10;
    let padded;
    let input = if samples.len() < min_len {
        let mut v = samples.to_vec();
        v.resize(min_len, 0.0);
        padded = v;
        &padded[..]
    } else {
        samples
    };

    state.full(params, input).map_err(|e| anyhow!("{e}"))?;
    let text = state
        .as_iter()
        .filter(|seg| seg.no_speech_probability() < NO_SPEECH_THRESHOLD)
        .filter_map(|seg| seg.to_str_lossy().ok().map(|s| s.trim().to_string()))
        .filter(|s| !is_noise_marker(s))
        .collect::<Vec<_>>()
        .join(" ");
    Ok(text.trim().to_string())
}

/// Whisper emits things like "[BLANK_AUDIO]", "(music)" or "♪" for non-speech.
fn is_noise_marker(s: &str) -> bool {
    let s = s.trim();
    s.is_empty()
        || (s.starts_with('[') && s.ends_with(']'))
        || (s.starts_with('(') && s.ends_with(')'))
        || s.chars().all(|c| !c.is_alphanumeric())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn noise_markers() {
        assert!(is_noise_marker("[BLANK_AUDIO]"));
        assert!(is_noise_marker("(upbeat music)"));
        assert!(is_noise_marker("♪ ♪"));
        assert!(!is_noise_marker("Hello there."));
    }
}
