//! End-to-end checks against real models. Ignored by default because they
//! need downloaded weights / a running Ollama:
//!
//!   cargo test -- --ignored --nocapture

use std::path::PathBuf;
use std::sync::mpsc;

use crate::audio::resample::Resampler;
use crate::db::Segment;
use crate::llm::ollama;
use crate::transcribe::{models, vad::Segmenter, whisper::Transcriber};

fn data_dir() -> PathBuf {
    let home = std::env::var("HOME").unwrap();
    PathBuf::from(home).join("Library/Application Support/dev.ruy.private-meeting-assistant")
}

#[test]
#[ignore]
fn jfk_clip_through_full_pipeline() {
    let fixture = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fixtures/jfk.wav");
    let speech: Vec<f32> = hound::WavReader::open(fixture)
        .unwrap()
        .into_samples::<i16>()
        .map(|s| s.unwrap() as f32 / 32_768.0)
        .collect();

    // Pad with room tone and run through 48 kHz and back, like a real device.
    let mut seed = 1u32;
    let mut room = |n: usize| -> Vec<f32> {
        (0..n)
            .map(|_| {
                seed = seed.wrapping_mul(1_664_525).wrapping_add(1_013_904_223);
                (seed as f32 / u32::MAX as f32 - 0.5) * 0.001
            })
            .collect()
    };
    let mut input = room(16_000);
    input.extend(&speech);
    input.extend(room(24_000));
    let mut up = Resampler::new(16_000, 48_000);
    let device_audio = up.process(&input);

    let mut down = Resampler::new(48_000, 16_000);
    let mut seg = Segmenter::new();
    let mut utterances = Vec::new();
    for chunk in device_audio.chunks(480) {
        utterances.extend(seg.push(&down.process(chunk)));
    }
    utterances.extend(seg.flush());
    assert!(!utterances.is_empty(), "segmenter found no speech");

    let t = Transcriber::load(&models::model_path(&data_dir(), "base.en")).unwrap();
    let (tx, rx) = mpsc::channel();
    for u in utterances {
        let tx = tx.clone();
        let start = u.start_ms();
        t.submit(u.samples, Some("en".into()), Box::new(move |text| tx.send((start, text)).unwrap()));
    }
    t.wait_idle();
    drop(tx);
    let lines: Vec<(i64, String)> = rx.iter().collect();
    for (ms, text) in &lines {
        println!("[{}] {text}", ollama::format_ts(*ms));
    }
    let all = lines.iter().map(|(_, t)| t.as_str()).collect::<Vec<_>>().join(" ").to_lowercase();
    assert!(all.contains("ask not what your country can do for you"), "{all}");
    assert!(lines[0].0 >= 500 && lines[0].0 <= 1_200, "first utterance at {} ms", lines[0].0);
}

#[test]
#[ignore]
fn ollama_produces_structured_summary() {
    let lines = [
        ("Me", "Okay, let's go over the launch plan for the new pricing page."),
        ("Them", "Design is done. Priya still needs to finish the copy for the enterprise tier."),
        ("Me", "Can we ship on Thursday then?"),
        ("Them", "Thursday works if copy lands by Wednesday. Let's agree on Thursday."),
        ("Me", "Great, decided. I'll send the announcement email to customers on Thursday morning."),
        ("Them", "And I'll set up the A/B test in the analytics dashboard."),
    ];
    let segments: Vec<Segment> = lines
        .iter()
        .enumerate()
        .map(|(i, (who, text))| Segment {
            id: i as i64,
            meeting_id: 1,
            speaker: who.to_string(),
            start_ms: i as i64 * 6_000,
            end_ms: i as i64 * 6_000 + 5_000,
            text: text.to_string(),
        })
        .collect();
    let settings = crate::settings::Settings::default();
    let rt = tokio::runtime::Runtime::new().unwrap();
    let s = rt
        .block_on(ollama::summarize(&settings.ollama_url, &settings.ollama_model, &segments))
        .unwrap();
    println!("{s:#?}");
    assert!(s.summary.to_lowercase().contains("pricing"));
    assert!(s.action_items.len() >= 2);
    assert!(s.action_items.iter().all(|a| !a.text.contains('\n')), "owner leaked into text");
    assert!(s.action_items.iter().any(|a| a.owner.as_deref() == Some("Me")));
    assert!(!s.decisions.is_empty());
}
