//! Summaries via a local Ollama server. Long transcripts are summarised in
//! chunks first (map) and the partial notes merged into one result (reduce).

use std::time::Duration;

use anyhow::{anyhow, Context, Result};
use serde::{Deserialize, Serialize};
use serde_json::json;

use super::Summary;
use crate::db::Segment;

/// Characters of transcript per map step; keeps prompts well inside the context window.
const CHUNK_CHARS: usize = 24_000;
const NUM_CTX: u32 = 16_384;

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct OllamaStatus {
    pub running: bool,
    pub models: Vec<String>,
    pub error: Option<String>,
}

fn client() -> reqwest::Client {
    reqwest::Client::builder()
        .timeout(Duration::from_secs(5 * 60))
        .build()
        .expect("building HTTP client")
}

pub async fn status(base_url: &str) -> OllamaStatus {
    #[derive(Deserialize)]
    struct Tags {
        models: Vec<Tag>,
    }
    #[derive(Deserialize)]
    struct Tag {
        name: String,
    }
    let res = async {
        let tags: Tags = reqwest::Client::new()
            .get(format!("{}/api/tags", base_url.trim_end_matches('/')))
            .timeout(Duration::from_secs(3))
            .send()
            .await?
            .error_for_status()?
            .json()
            .await?;
        anyhow::Ok(tags.models.into_iter().map(|m| m.name).collect::<Vec<_>>())
    }
    .await;
    match res {
        Ok(models) => OllamaStatus { running: true, models, error: None },
        Err(e) => OllamaStatus { running: false, models: vec![], error: Some(e.to_string()) },
    }
}

pub fn format_ts(ms: i64) -> String {
    let s = ms / 1000;
    if s >= 3600 {
        format!("{}:{:02}:{:02}", s / 3600, (s / 60) % 60, s % 60)
    } else {
        format!("{:02}:{:02}", s / 60, s % 60)
    }
}

pub fn transcript_text(segments: &[Segment]) -> String {
    segments
        .iter()
        .map(|s| format!("[{}] {}: {}", format_ts(s.start_ms), s.speaker, s.text))
        .collect::<Vec<_>>()
        .join("\n")
}

/// Splits on line boundaries into chunks of at most ~`max` characters.
fn chunk_lines(text: &str, max: usize) -> Vec<String> {
    let mut chunks = vec![String::new()];
    for line in text.lines() {
        let cur = chunks.last_mut().unwrap();
        if !cur.is_empty() && cur.len() + line.len() + 1 > max {
            chunks.push(String::new());
        }
        let cur = chunks.last_mut().unwrap();
        if !cur.is_empty() {
            cur.push('\n');
        }
        cur.push_str(line);
    }
    chunks
}

const SPEAKER_NOTE: &str = "\"Me\" is the person who recorded the meeting; \"Them\" is everyone \
heard through the computer's audio (possibly several people).";

async fn chat(base_url: &str, model: &str, prompt: String, format: Option<serde_json::Value>) -> Result<String> {
    #[derive(Deserialize)]
    struct Resp {
        message: Msg,
    }
    #[derive(Deserialize)]
    struct Msg {
        content: String,
    }
    let mut body = json!({
        "model": model,
        "stream": false,
        // Reasoning models are far slower and can loop under a JSON schema.
        "think": false,
        "messages": [{ "role": "user", "content": prompt }],
        "options": { "num_ctx": NUM_CTX, "temperature": 0.2 },
    });
    if let Some(f) = format {
        body["format"] = f;
    }
    let url = format!("{}/api/chat", base_url.trim_end_matches('/'));
    let mut resp = send(&url, &body).await?;
    if resp.status() == reqwest::StatusCode::BAD_REQUEST {
        // Older servers / some models reject the `think` flag.
        body.as_object_mut().unwrap().remove("think");
        resp = send(&url, &body).await?;
    }
    if !resp.status().is_success() {
        let status = resp.status();
        let text = resp.text().await.unwrap_or_default();
        return Err(anyhow!("Ollama returned {status}: {text}"));
    }
    Ok(resp.json::<Resp>().await?.message.content)
}

async fn send(url: &str, body: &serde_json::Value) -> Result<reqwest::Response> {
    client().post(url).json(body).send().await.map_err(|e| {
        if e.is_timeout() {
            anyhow!("Ollama took longer than 5 minutes to respond. Try a smaller model in Settings.")
        } else {
            anyhow!(e).context("Ollama isn't reachable — is it running?")
        }
    })
}

fn summary_schema() -> serde_json::Value {
    json!({
        "type": "object",
        "properties": {
            "summary": { "type": "string" },
            "decisions": { "type": "array", "items": { "type": "string" } },
            "actionItems": {
                "type": "array",
                "items": {
                    "type": "object",
                    "properties": {
                        "text": { "type": "string" },
                        "owner": { "type": "string" }
                    },
                    "required": ["text", "owner"]
                }
            }
        },
        "required": ["summary", "decisions", "actionItems"]
    })
}

pub async fn summarize(base_url: &str, model: &str, segments: &[Segment]) -> Result<Summary> {
    let transcript = transcript_text(segments);
    if transcript.trim().is_empty() {
        return Err(anyhow!("the transcript is empty"));
    }

    let chunks = chunk_lines(&transcript, CHUNK_CHARS);
    let material = if chunks.len() == 1 {
        format!("Transcript:\n{transcript}")
    } else {
        let mut notes = Vec::new();
        for (i, chunk) in chunks.iter().enumerate() {
            let prompt = format!(
                "You are taking notes on part {} of {} of a meeting transcript. {SPEAKER_NOTE}\n\
                 Write concise bullet-point notes covering topics discussed, any decisions made, \
                 and any tasks or commitments (with who owns them). Keep timestamps for key moments.\n\n\
                 Transcript part:\n{chunk}",
                i + 1,
                chunks.len()
            );
            notes.push(chat(base_url, model, prompt, None).await?);
        }
        format!("Notes from consecutive parts of the meeting:\n\n{}", notes.join("\n\n---\n\n"))
    };

    let prompt = format!(
        "You are a meeting assistant. {SPEAKER_NOTE}\n\
         Produce JSON with:\n\
         - \"summary\": a short paragraph (3-6 sentences) of what the meeting was about and its outcome\n\
         - \"decisions\": decisions that were actually agreed (empty list if none)\n\
         - \"actionItems\": concrete follow-up tasks, each with \"text\" and \"owner\" (\"Me\", a name \
         mentioned in the meeting, or \"\" if unclear). Keep the owner out of \"text\". Only include tasks someone committed to or was asked to do.\n\
         Use only information present in the material. Do not invent names.\n\n{material}"
    );
    let raw = chat(base_url, model, prompt, Some(summary_schema())).await?;
    parse_summary(&raw)
}

fn parse_summary(raw: &str) -> Result<Summary> {
    // Some models wrap JSON in prose or code fences despite `format`.
    let start = raw.find('{').ok_or_else(|| anyhow!("model returned no JSON: {raw}"))?;
    let end = raw.rfind('}').ok_or_else(|| anyhow!("model returned no JSON: {raw}"))?;
    let mut summary: Summary =
        serde_json::from_str(&raw[start..=end]).context("parsing model output")?;
    summary.action_items.retain(|a| !a.text.trim().is_empty());
    for a in &mut summary.action_items {
        a.done = false;
        if a.owner.as_deref().is_some_and(|o| o.trim().is_empty() || o.eq_ignore_ascii_case("null")) {
            a.owner = None;
        }
    }
    Ok(summary)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn chunks_respect_limit() {
        let text = (0..100).map(|i| format!("line {i} {}", "x".repeat(50))).collect::<Vec<_>>().join("\n");
        let chunks = chunk_lines(&text, 500);
        assert!(chunks.len() > 10);
        assert!(chunks.iter().all(|c| c.len() <= 500));
        assert_eq!(chunks.join("\n"), text);
    }

    #[test]
    fn parses_fenced_json() {
        let raw = "```json\n{\"summary\":\"S\",\"decisions\":[\"D\"],\"actionItems\":[{\"text\":\"T\",\"owner\":\"null\"},{\"text\":\" \"}]}\n```";
        let s = parse_summary(raw).unwrap();
        assert_eq!(s.summary, "S");
        assert_eq!(s.action_items.len(), 1);
        assert_eq!(s.action_items[0].owner, None);
    }

    #[test]
    fn timestamps() {
        assert_eq!(format_ts(65_000), "01:05");
        assert_eq!(format_ts(3_725_000), "1:02:05");
    }
}
