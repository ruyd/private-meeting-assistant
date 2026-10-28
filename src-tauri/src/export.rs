use crate::db::{Meeting, Segment};
use crate::llm::ollama::format_ts;

pub fn to_markdown(m: &Meeting, segments: &[Segment]) -> String {
    let mut out = format!("# {}\n\n", m.title);
    out.push_str(&format!("*{}* · {} min\n\n", local_time(&m.started_at), (m.duration_ms + 59_999) / 60_000));

    if let Some(s) = &m.summary {
        out.push_str("## Summary\n\n");
        out.push_str(s.summary.trim());
        out.push_str("\n\n");
        if !s.decisions.is_empty() {
            out.push_str("## Decisions\n\n");
            for d in &s.decisions {
                out.push_str(&format!("- {d}\n"));
            }
            out.push('\n');
        }
        if !s.action_items.is_empty() {
            out.push_str("## Action items\n\n");
            for a in &s.action_items {
                let owner = a.owner.as_ref().map(|o| format!(" — *{o}*")).unwrap_or_default();
                out.push_str(&format!("- [{}] {}{owner}\n", if a.done { "x" } else { " " }, a.text));
            }
            out.push('\n');
        }
    }

    out.push_str("## Transcript\n\n");
    for s in segments {
        out.push_str(&format!("**[{}] {}:** {}\n\n", format_ts(s.start_ms), s.speaker, s.text));
    }
    out
}

pub fn local_time(rfc3339: &str) -> String {
    chrono::DateTime::parse_from_rfc3339(rfc3339)
        .map(|t| t.with_timezone(&chrono::Local).format("%a %b %-d, %Y %H:%M").to_string())
        .unwrap_or_else(|_| rfc3339.to_string())
}

/// File-name-safe version of a meeting title.
pub fn file_name(title: &str) -> String {
    let cleaned: String = title
        .chars()
        .map(|c| if c.is_alphanumeric() || " -_.".contains(c) { c } else { '-' })
        .collect();
    let cleaned = cleaned.trim().trim_matches('.');
    if cleaned.is_empty() { "meeting".into() } else { cleaned.chars().take(80).collect() }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::llm::{ActionItem, Summary};

    #[test]
    fn renders_markdown() {
        let m = Meeting {
            id: 1,
            title: "Sync".into(),
            started_at: "2026-10-27T10:00:00Z".into(),
            ended_at: None,
            audio_dir: None,
            summary: Some(Summary {
                summary: "We met.".into(),
                decisions: vec!["Ship it".into()],
                action_items: vec![ActionItem { text: "Write docs".into(), owner: Some("Me".into()), done: true }],
            }),
            summary_status: "done".into(),
            segment_count: 1,
            duration_ms: 61_000,
        };
        let seg = Segment { id: 1, meeting_id: 1, speaker: "Them".into(), start_ms: 61_000, end_ms: 62_000, text: "Hi".into() };
        let md = to_markdown(&m, &[seg]);
        assert!(md.contains("# Sync"));
        assert!(md.contains("2 min"));
        assert!(md.contains("- [x] Write docs — *Me*"));
        assert!(md.contains("**[01:01] Them:** Hi"));
    }

    #[test]
    fn safe_file_names() {
        assert_eq!(file_name("Q3 / budget: review?"), "Q3 - budget- review-");
        assert_eq!(file_name("../.."), "-");
        assert_eq!(file_name("   "), "meeting");
    }
}
