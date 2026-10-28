//! Energy-based voice activity segmentation with an adaptive noise floor.
//!
//! Cuts a continuous 16 kHz stream into utterances so each one can be sent to
//! Whisper as soon as the speaker pauses. Whisper's own no-speech probability
//! filters out whatever non-speech noise gets past this stage.

use crate::audio::TARGET_RATE;

const FRAME: usize = (TARGET_RATE as usize) * 30 / 1000; // 30 ms
const PRE_ROLL_FRAMES: usize = 10; // 300 ms kept before speech onset
const HANGOVER_FRAMES: usize = 23; // ~700 ms of silence ends an utterance
const MIN_SPEECH_FRAMES: usize = 8; // drop blips shorter than ~240 ms
const MAX_FRAMES: usize = 15_000 / 30; // force a cut every 15 s
/// Speech must be this many times louder than the noise floor (≈ +10 dB)...
const FLOOR_RATIO: f32 = 3.2;
/// ...and above this absolute level (≈ -50 dBFS).
const ABS_THRESHOLD: f32 = 0.003;

#[derive(Debug)]
pub struct Utterance {
    /// Offset of the first sample from the start of the stream.
    pub start_sample: u64,
    pub samples: Vec<f32>,
}

impl Utterance {
    pub fn start_ms(&self) -> i64 {
        (self.start_sample * 1000 / TARGET_RATE as u64) as i64
    }
    pub fn end_ms(&self) -> i64 {
        self.start_ms() + (self.samples.len() as u64 * 1000 / TARGET_RATE as u64) as i64
    }
}

pub struct Segmenter {
    pending: Vec<f32>,
    /// Absolute sample index of `pending[0]`.
    pending_start: u64,
    noise_floor: f32,
    pre_roll: std::collections::VecDeque<Vec<f32>>,
    current: Option<Current>,
}

struct Current {
    start_sample: u64,
    samples: Vec<f32>,
    frames: usize,
    speech_frames: usize,
    silent_run: usize,
}

impl Default for Segmenter {
    fn default() -> Self {
        Self::new()
    }
}

impl Segmenter {
    pub fn new() -> Self {
        Self {
            pending: Vec::new(),
            pending_start: 0,
            noise_floor: 0.001,
            pre_roll: Default::default(),
            current: None,
        }
    }

    pub fn push(&mut self, samples: &[f32]) -> Vec<Utterance> {
        self.pending.extend_from_slice(samples);
        let mut out = Vec::new();
        let mut offset = 0;
        while self.pending.len() - offset >= FRAME {
            let frame = self.pending[offset..offset + FRAME].to_vec();
            let frame_start = self.pending_start + offset as u64;
            if let Some(u) = self.frame(frame, frame_start) {
                out.push(u);
            }
            offset += FRAME;
        }
        self.pending.drain(..offset);
        self.pending_start += offset as u64;
        out
    }

    /// Emits whatever utterance is in progress (call when recording stops).
    pub fn flush(&mut self) -> Option<Utterance> {
        let mut cur = self.current.take()?;
        cur.samples.extend(self.pending.drain(..));
        (cur.speech_frames >= MIN_SPEECH_FRAMES).then(|| Utterance {
            start_sample: cur.start_sample,
            samples: cur.samples,
        })
    }

    fn frame(&mut self, frame: Vec<f32>, frame_start: u64) -> Option<Utterance> {
        let rms = (frame.iter().map(|s| s * s).sum::<f32>() / frame.len() as f32).sqrt();
        let is_speech = rms > ABS_THRESHOLD && rms > self.noise_floor * FLOOR_RATIO;

        // Track the floor: drop quickly to quieter levels, rise slowly so
        // sustained speech doesn't get absorbed into it.
        if !is_speech {
            self.noise_floor = if rms < self.noise_floor {
                0.7 * self.noise_floor + 0.3 * rms
            } else {
                0.995 * self.noise_floor + 0.005 * rms
            }
            .max(1e-5);
        }

        match self.current.as_mut() {
            None => {
                if is_speech {
                    let pre: Vec<f32> = self.pre_roll.drain(..).flatten().collect();
                    let start_sample = frame_start - pre.len() as u64;
                    let mut samples = pre;
                    samples.extend_from_slice(&frame);
                    self.current = Some(Current {
                        start_sample,
                        samples,
                        frames: 1,
                        speech_frames: 1,
                        silent_run: 0,
                    });
                } else {
                    self.pre_roll.push_back(frame);
                    if self.pre_roll.len() > PRE_ROLL_FRAMES {
                        self.pre_roll.pop_front();
                    }
                }
                None
            }
            Some(cur) => {
                cur.samples.extend_from_slice(&frame);
                cur.frames += 1;
                if is_speech {
                    cur.speech_frames += 1;
                    cur.silent_run = 0;
                } else {
                    cur.silent_run += 1;
                }
                let ended = cur.silent_run >= HANGOVER_FRAMES;
                if !ended && cur.frames < MAX_FRAMES {
                    return None;
                }
                let cur = self.current.take().unwrap();
                if cur.speech_frames < MIN_SPEECH_FRAMES {
                    return None;
                }
                let mut samples = cur.samples;
                if ended {
                    // Trim most of the trailing silence, keep a short tail.
                    let keep_tail = 8 * FRAME;
                    let trim = (cur.silent_run * FRAME).saturating_sub(keep_tail);
                    samples.truncate(samples.len() - trim);
                }
                Some(Utterance { start_sample: cur.start_sample, samples })
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::f32::consts::PI;

    fn noise(n: usize, amp: f32, seed: &mut u32) -> Vec<f32> {
        (0..n)
            .map(|_| {
                *seed = seed.wrapping_mul(1_664_525).wrapping_add(1_013_904_223);
                (*seed as f32 / u32::MAX as f32 * 2.0 - 1.0) * amp
            })
            .collect()
    }

    fn voice(n: usize) -> Vec<f32> {
        (0..n)
            .map(|i| 0.3 * (2.0 * PI * 220.0 * i as f32 / 16_000.0).sin())
            .collect()
    }

    #[test]
    fn splits_two_utterances_on_pause() {
        let mut seed = 7;
        let mut stream = noise(16_000, 0.0005, &mut seed); // 1 s room tone
        stream.extend(voice(24_000)); // 1.5 s speech at t=1.0
        stream.extend(noise(24_000, 0.0005, &mut seed)); // 1.5 s pause
        stream.extend(voice(16_000)); // 1 s speech at t=4.0
        stream.extend(noise(16_000, 0.0005, &mut seed));

        let mut seg = Segmenter::new();
        let mut utts = Vec::new();
        for chunk in stream.chunks(1_000) {
            utts.extend(seg.push(chunk));
        }
        utts.extend(seg.flush());

        assert_eq!(utts.len(), 2, "{utts:?}");
        // Starts include ~300 ms pre-roll.
        assert!((650..=1000).contains(&utts[0].start_ms()), "{}", utts[0].start_ms());
        assert!((3650..=4000).contains(&utts[1].start_ms()), "{}", utts[1].start_ms());
        assert!(utts[0].end_ms() < 3_000);
    }

    #[test]
    fn ignores_silence_and_blips() {
        let mut seed = 3;
        let mut stream = noise(32_000, 0.0005, &mut seed);
        stream.extend(voice(1_600)); // 100 ms click
        stream.extend(noise(32_000, 0.0005, &mut seed));
        let mut seg = Segmenter::new();
        let mut n = 0;
        for chunk in stream.chunks(777) {
            n += seg.push(chunk).len();
        }
        n += seg.flush().into_iter().count();
        assert_eq!(n, 0);
    }

    #[test]
    fn forces_cut_on_long_monologue() {
        let mut seg = Segmenter::new();
        let mut utts = Vec::new();
        for chunk in voice(16_000 * 40).chunks(4_000) {
            utts.extend(seg.push(chunk));
        }
        utts.extend(seg.flush());
        assert!(utts.len() >= 3);
        assert!(utts.iter().all(|u| u.samples.len() <= 16_000 * 16));
    }
}
