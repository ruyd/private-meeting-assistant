//! Streaming band-limited resampler (windowed-sinc interpolation).
//!
//! Accepts arbitrary-sized input chunks and produces output at the target
//! rate. The sinc cutoff is scaled when downsampling so content above the new
//! Nyquist is filtered out instead of aliasing into the speech band.

use std::f64::consts::PI;

/// Zero crossings of the sinc kernel on each side of the centre.
const ZERO_CROSSINGS: f64 = 16.0;

pub struct Resampler {
    /// Input samples advanced per output sample.
    step: f64,
    cutoff: f64,
    /// Kernel half-width in input samples.
    width: usize,
    buf: Vec<f32>,
    /// Position of the next output sample, in `buf` coordinates.
    pos: f64,
    passthrough: bool,
}

impl Resampler {
    pub fn new(in_rate: u32, out_rate: u32) -> Self {
        let ratio = out_rate as f64 / in_rate as f64;
        let cutoff = ratio.min(1.0) * 0.95;
        let width = (ZERO_CROSSINGS / cutoff).ceil() as usize;
        Self {
            step: 1.0 / ratio,
            cutoff,
            width,
            // Leading zeros let the first outputs see a full kernel.
            buf: vec![0.0; width],
            pos: width as f64,
            passthrough: in_rate == out_rate,
        }
    }

    pub fn process(&mut self, input: &[f32]) -> Vec<f32> {
        if self.passthrough {
            return input.to_vec();
        }
        self.buf.extend_from_slice(input);
        let mut out = Vec::with_capacity((input.len() as f64 / self.step) as usize + 1);
        let w = self.width as isize;
        while self.pos + (self.width as f64) < self.buf.len() as f64 {
            let center = self.pos.floor() as isize;
            let mut acc = 0.0f64;
            for k in (center - w + 1)..=(center + w) {
                let d = self.pos - k as f64;
                let x = d / self.width as f64;
                if x.abs() >= 1.0 {
                    continue;
                }
                let window = 0.5 * (1.0 + (PI * x).cos());
                acc += self.buf[k as usize] as f64 * self.cutoff * sinc(self.cutoff * d) * window;
            }
            out.push(acc as f32);
            self.pos += self.step;
        }
        // Keep only the history the kernel still needs.
        let consumed = (self.pos.floor() as usize).saturating_sub(self.width);
        if consumed > 0 {
            self.buf.drain(..consumed);
            self.pos -= consumed as f64;
        }
        out
    }

    #[cfg(test)]
    /// Drains the samples still held back by the kernel's look-ahead.
    pub fn flush(&mut self) -> Vec<f32> {
        if self.passthrough {
            return vec![];
        }
        self.process(&vec![0.0; self.width + 1])
    }
}

fn sinc(x: f64) -> f64 {
    if x.abs() < 1e-9 {
        1.0
    } else {
        (PI * x).sin() / (PI * x)
    }
}

/// Averages interleaved frames down to mono.
pub fn downmix_interleaved(data: &[f32], channels: usize) -> Vec<f32> {
    if channels <= 1 {
        return data.to_vec();
    }
    data.chunks_exact(channels)
        .map(|f| f.iter().sum::<f32>() / channels as f32)
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tone(freq: f64, rate: u32, secs: f64) -> Vec<f32> {
        (0..(rate as f64 * secs) as usize)
            .map(|i| (2.0 * PI * freq * i as f64 / rate as f64).sin() as f32)
            .collect()
    }

    fn rms(x: &[f32]) -> f32 {
        (x.iter().map(|v| v * v).sum::<f32>() / x.len() as f32).sqrt()
    }

    fn resample_chunked(input: &[f32], from: u32, to: u32, chunk: usize) -> Vec<f32> {
        let mut r = Resampler::new(from, to);
        let mut out = Vec::new();
        for c in input.chunks(chunk) {
            out.extend(r.process(c));
        }
        out.extend(r.flush());
        out
    }

    #[test]
    fn keeps_speech_band_and_length() {
        let input = tone(1000.0, 48_000, 1.0);
        let out = resample_chunked(&input, 48_000, 16_000, 441);
        assert!((out.len() as i64 - 16_000).abs() < 40, "len {}", out.len());
        // Skip edges; a full-scale sine has RMS 1/sqrt(2).
        let mid = &out[1000..15_000];
        assert!((rms(mid) - 0.7071).abs() < 0.02, "rms {}", rms(mid));
        // ~1 kHz: count upward zero crossings over 14000 samples (0.875 s).
        let crossings = mid.windows(2).filter(|w| w[0] < 0.0 && w[1] >= 0.0).count();
        assert!((870..=880).contains(&crossings), "crossings {crossings}");
    }

    #[test]
    fn rejects_content_above_new_nyquist() {
        let input = tone(10_000.0, 48_000, 1.0);
        let out = resample_chunked(&input, 48_000, 16_000, 1024);
        assert!(rms(&out[1000..15_000]) < 0.02, "aliasing rms {}", rms(&out[1000..15_000]));
    }

    #[test]
    fn handles_44k1() {
        let input = tone(440.0, 44_100, 0.5);
        let out = resample_chunked(&input, 44_100, 16_000, 512);
        assert!((out.len() as i64 - 8_000).abs() < 40, "len {}", out.len());
        assert!((rms(&out[500..7_500]) - 0.7071).abs() < 0.02);
    }

    #[test]
    fn downmix() {
        assert_eq!(downmix_interleaved(&[1.0, 0.0, 0.5, 0.5], 2), vec![0.5, 0.5]);
    }
}
