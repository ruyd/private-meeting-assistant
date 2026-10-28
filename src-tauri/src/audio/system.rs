//! System-audio capture via ScreenCaptureKit (macOS 13+). This is what hears
//! the other people on a Zoom / Meet / Teams call. Needs the Screen &
//! System Audio Recording permission.

use std::sync::Mutex;

use anyhow::{anyhow, Context, Result};
use crossbeam_channel::Sender;
use screencapturekit::cm::AudioBufferList;
use screencapturekit::prelude::*;

use super::resample::{downmix_interleaved, Resampler};
use super::{AudioChunk, Capture, Source, TARGET_RATE};

const CAPTURE_RATE: u32 = 48_000;

pub struct SystemCapture {
    stream: SCStream,
}

impl Capture for SystemCapture {
    fn stop(self: Box<Self>) {
        if let Err(e) = self.stream.stop_capture() {
            eprintln!("stopping system audio capture: {e:?}");
        }
    }
}

pub fn start(tx: Sender<AudioChunk>) -> Result<Box<dyn Capture>> {
    let content = SCShareableContent::get().map_err(|e| {
        anyhow!(
            "Can't access system audio ({e:?}). Grant \"Screen & System Audio Recording\" \
             permission in System Settings → Privacy & Security, then restart the app."
        )
    })?;
    let display = content
        .displays()
        .into_iter()
        .next()
        .ok_or_else(|| anyhow!("no display available for audio capture"))?;

    let filter = SCContentFilter::create()
        .with_display(&display)
        .with_excluding_windows(&[])
        .build()
        .map_err(|e| anyhow!("building capture filter: {e:?}"))?;

    // Video can't be disabled entirely; keep it as small as possible.
    let config = SCStreamConfiguration::new()
        .with_width(2)
        .with_height(2)
        .with_captures_audio(true)
        .with_excludes_current_process_audio(true)
        .with_sample_rate(CAPTURE_RATE as i32)
        .with_channel_count(2);

    let resampler = Mutex::new(Resampler::new(CAPTURE_RATE, TARGET_RATE));
    let handler = move |sample: CMSampleBuffer, _kind: SCStreamOutputType| {
        let Ok(list) = sample.audio_buffer_list() else {
            return;
        };
        let mono = to_mono(&list);
        if mono.is_empty() {
            return;
        }
        let samples = resampler.lock().unwrap_or_else(|e| e.into_inner()).process(&mono);
        if !samples.is_empty() {
            let _ = tx.send(AudioChunk { source: Source::System, samples });
        }
    };

    let mut stream = SCStream::new(&filter, &config).map_err(|e| anyhow!("{e:?}"))?;
    stream
        .add_output_handler(handler, SCStreamOutputType::Audio)
        .map_err(|e| anyhow!("{e:?}"))?;
    stream
        .start_capture()
        .map_err(|e| anyhow!("{e:?}"))
        .context("starting system audio capture")?;
    Ok(Box::new(SystemCapture { stream }))
}

fn f32s(bytes: &[u8]) -> impl Iterator<Item = f32> + '_ {
    bytes
        .chunks_exact(4)
        .map(|b| f32::from_ne_bytes([b[0], b[1], b[2], b[3]]))
}

/// ScreenCaptureKit delivers Float32 PCM, usually non-interleaved (one
/// buffer per channel); handle the interleaved layout too.
fn to_mono(list: &AudioBufferList) -> Vec<f32> {
    let n = list.num_buffers();
    if n == 0 {
        return vec![];
    }
    if n == 1 {
        let buf = list.get(0).unwrap();
        let data: Vec<f32> = f32s(buf.data()).collect();
        return downmix_interleaved(&data, buf.number_channels.max(1) as usize);
    }
    let channels: Vec<Vec<f32>> = list.iter().map(|b| f32s(b.data()).collect()).collect();
    let len = channels.iter().map(Vec::len).min().unwrap_or(0);
    (0..len)
        .map(|i| channels.iter().map(|c| c[i]).sum::<f32>() / n as f32)
        .collect()
}
