//! Microphone capture via cpal. The cpal stream isn't `Send` on every
//! platform, so it lives on its own thread until told to stop.

use std::sync::mpsc;
use std::thread::JoinHandle;

use anyhow::{anyhow, Result};
use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use cpal::SampleFormat;
use crossbeam_channel::Sender;

use super::resample::{downmix_interleaved, Resampler};
use super::{AudioChunk, Capture, Source, TARGET_RATE};

pub struct MicCapture {
    stop_tx: mpsc::Sender<()>,
    thread: Option<JoinHandle<()>>,
}

impl Capture for MicCapture {
    fn stop(mut self: Box<Self>) {
        let _ = self.stop_tx.send(());
        if let Some(t) = self.thread.take() {
            let _ = t.join();
        }
    }
}

pub fn start(tx: Sender<AudioChunk>) -> Result<Box<dyn Capture>> {
    let (stop_tx, stop_rx) = mpsc::channel::<()>();
    let (ready_tx, ready_rx) = mpsc::channel::<Result<()>>();

    let thread = std::thread::Builder::new()
        .name("mic-capture".into())
        .spawn(move || {
            let stream = match build_stream(tx) {
                Ok(s) => s,
                Err(e) => {
                    let _ = ready_tx.send(Err(e));
                    return;
                }
            };
            let _ = ready_tx.send(Ok(()));
            // Block until stop is requested (or the owner is dropped).
            let _ = stop_rx.recv();
            drop(stream);
        })?;

    ready_rx
        .recv()
        .map_err(|_| anyhow!("microphone thread exited unexpectedly"))??;
    Ok(Box::new(MicCapture { stop_tx, thread: Some(thread) }))
}

fn build_stream(tx: Sender<AudioChunk>) -> Result<cpal::Stream> {
    let host = cpal::default_host();
    let device = host
        .default_input_device()
        .ok_or_else(|| anyhow!("no microphone found"))?;
    let config = device.default_input_config()?;
    let channels = config.channels() as usize;
    let format = config.sample_format();
    let mut resampler = Resampler::new(config.sample_rate(), TARGET_RATE);

    let mut push = move |interleaved: Vec<f32>| {
        let mono = downmix_interleaved(&interleaved, channels);
        let samples = resampler.process(&mono);
        if !samples.is_empty() {
            let _ = tx.send(AudioChunk { source: Source::Mic, samples });
        }
    };
    let on_err = |err| eprintln!("microphone stream error: {err}");

    let stream = match format {
        SampleFormat::F32 => device.build_input_stream(
            config.into(),
            move |data: &[f32], _: &_| push(data.to_vec()),
            on_err,
            None,
        )?,
        SampleFormat::I16 => device.build_input_stream(
            config.into(),
            move |data: &[i16], _: &_| push(data.iter().map(|&s| s as f32 / 32_768.0).collect()),
            on_err,
            None,
        )?,
        SampleFormat::I32 => device.build_input_stream(
            config.into(),
            move |data: &[i32], _: &_| {
                push(data.iter().map(|&s| s as f32 / 2_147_483_648.0).collect())
            },
            on_err,
            None,
        )?,
        other => return Err(anyhow!("unsupported microphone sample format {other}")),
    };
    stream.play()?;
    Ok(stream)
}
