use std::path::Path;
use std::sync::{Arc, Mutex, MutexGuard};

use anyhow::{Context, Result};
use rusqlite::{params, Connection, OptionalExtension};
use serde::Serialize;

use crate::llm::Summary;
use crate::settings::Settings;

/// Marks the start / end of a highlighted match inside search snippets.
/// Control characters (not HTML) so the UI never has to inject markup.
pub const HL_START: &str = "\u{1}";
pub const HL_END: &str = "\u{2}";

#[derive(Clone)]
pub struct Db(Arc<Mutex<Connection>>);

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Meeting {
    pub id: i64,
    pub title: String,
    pub started_at: String,
    pub ended_at: Option<String>,
    pub audio_dir: Option<String>,
    pub summary: Option<Summary>,
    pub summary_status: String,
    pub segment_count: i64,
    pub duration_ms: i64,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Segment {
    pub id: i64,
    pub meeting_id: i64,
    pub speaker: String,
    pub start_ms: i64,
    pub end_ms: i64,
    pub text: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SearchHit {
    pub meeting_id: i64,
    pub meeting_title: String,
    pub started_at: String,
    /// "transcript" or "summary"
    pub kind: String,
    pub segment_id: Option<i64>,
    pub speaker: Option<String>,
    pub start_ms: Option<i64>,
    pub snippet: String,
}

const MEETING_COLS: &str = "m.id, m.title, m.started_at, m.ended_at, m.audio_dir, m.summary_json, m.summary_status,
     (SELECT COUNT(*) FROM segments s WHERE s.meeting_id = m.id),
     COALESCE((SELECT MAX(end_ms) FROM segments s WHERE s.meeting_id = m.id), 0)";

fn meeting_from_row(row: &rusqlite::Row) -> rusqlite::Result<Meeting> {
    let summary_json: Option<String> = row.get(5)?;
    Ok(Meeting {
        id: row.get(0)?,
        title: row.get(1)?,
        started_at: row.get(2)?,
        ended_at: row.get(3)?,
        audio_dir: row.get(4)?,
        summary: summary_json.and_then(|s| serde_json::from_str(&s).ok()),
        summary_status: row.get(6)?,
        segment_count: row.get(7)?,
        duration_ms: row.get(8)?,
    })
}

/// Turns free-form user input into a safe FTS5 query: every word is quoted
/// (so operators and punctuation can't cause syntax errors) and the last one
/// gets a prefix wildcard for search-as-you-type.
pub fn fts_query(input: &str) -> Option<String> {
    let words: Vec<String> = input
        .split_whitespace()
        .map(|w| w.replace('"', ""))
        .filter(|w| !w.is_empty())
        .map(|w| format!("\"{w}\""))
        .collect();
    if words.is_empty() {
        return None;
    }
    Some(format!("{}*", words.join(" ")))
}

impl Db {
    pub fn open(path: &Path) -> Result<Self> {
        let conn = Connection::open(path).with_context(|| format!("opening {}", path.display()))?;
        Self::init(conn)
    }

    #[cfg(test)]
    pub fn open_in_memory() -> Result<Self> {
        Self::init(Connection::open_in_memory()?)
    }

    fn init(conn: Connection) -> Result<Self> {
        conn.pragma_update(None, "journal_mode", "WAL")?;
        conn.execute_batch(include_str!("schema.sql"))?;
        // A recording that was running when the app quit is left without an
        // end time; close it so it doesn't look "live" forever.
        conn.execute(
            "UPDATE meetings SET ended_at = started_at WHERE ended_at IS NULL",
            [],
        )?;
        conn.execute(
            "UPDATE meetings SET summary_status = 'none' WHERE summary_status = 'running'",
            [],
        )?;
        Ok(Self(Arc::new(Mutex::new(conn))))
    }

    fn conn(&self) -> MutexGuard<'_, Connection> {
        self.0.lock().unwrap_or_else(|e| e.into_inner())
    }

    // --- settings -------------------------------------------------------

    pub fn settings(&self) -> Result<Settings> {
        let raw: Option<String> = self
            .conn()
            .query_row("SELECT value FROM settings WHERE key = 'settings'", [], |r| r.get(0))
            .optional()?;
        Ok(raw
            .and_then(|s| serde_json::from_str(&s).ok())
            .unwrap_or_default())
    }

    pub fn save_settings(&self, s: &Settings) -> Result<()> {
        self.conn().execute(
            "INSERT INTO settings(key, value) VALUES ('settings', ?1)
             ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            params![serde_json::to_string(s)?],
        )?;
        Ok(())
    }

    // --- meetings -------------------------------------------------------

    pub fn create_meeting(&self, title: &str, started_at: &str) -> Result<i64> {
        let conn = self.conn();
        conn.execute(
            "INSERT INTO meetings(title, started_at) VALUES (?1, ?2)",
            params![title, started_at],
        )?;
        let id = conn.last_insert_rowid();
        conn.execute(
            "INSERT INTO meetings_fts(meeting_id, title, summary) VALUES (?1, ?2, '')",
            params![id, title],
        )?;
        Ok(id)
    }

    pub fn set_audio_dir(&self, id: i64, dir: &str) -> Result<()> {
        self.conn()
            .execute("UPDATE meetings SET audio_dir = ?2 WHERE id = ?1", params![id, dir])?;
        Ok(())
    }

    pub fn end_meeting(&self, id: i64, ended_at: &str) -> Result<()> {
        self.conn()
            .execute("UPDATE meetings SET ended_at = ?2 WHERE id = ?1", params![id, ended_at])?;
        Ok(())
    }

    pub fn rename_meeting(&self, id: i64, title: &str) -> Result<()> {
        let conn = self.conn();
        conn.execute("UPDATE meetings SET title = ?2 WHERE id = ?1", params![id, title])?;
        conn.execute(
            "UPDATE meetings_fts SET title = ?2 WHERE meeting_id = ?1",
            params![id, title],
        )?;
        Ok(())
    }

    pub fn delete_meeting(&self, id: i64) -> Result<Option<String>> {
        let conn = self.conn();
        let audio_dir: Option<String> = conn
            .query_row("SELECT audio_dir FROM meetings WHERE id = ?1", [id], |r| r.get(0))
            .optional()?
            .flatten();
        conn.execute("DELETE FROM meetings_fts WHERE meeting_id = ?1", [id])?;
        conn.execute("DELETE FROM segments WHERE meeting_id = ?1", [id])?;
        conn.execute("DELETE FROM meetings WHERE id = ?1", [id])?;
        Ok(audio_dir)
    }

    pub fn list_meetings(&self) -> Result<Vec<Meeting>> {
        let conn = self.conn();
        let mut stmt = conn.prepare(&format!(
            "SELECT {MEETING_COLS} FROM meetings m ORDER BY m.started_at DESC, m.id DESC"
        ))?;
        let rows = stmt.query_map([], meeting_from_row)?;
        Ok(rows.collect::<rusqlite::Result<_>>()?)
    }

    pub fn get_meeting(&self, id: i64) -> Result<Option<Meeting>> {
        Ok(self
            .conn()
            .query_row(
                &format!("SELECT {MEETING_COLS} FROM meetings m WHERE m.id = ?1"),
                [id],
                meeting_from_row,
            )
            .optional()?)
    }

    pub fn set_summary_status(&self, id: i64, status: &str) -> Result<()> {
        self.conn().execute(
            "UPDATE meetings SET summary_status = ?2 WHERE id = ?1",
            params![id, status],
        )?;
        Ok(())
    }

    pub fn save_summary(&self, id: i64, summary: &Summary) -> Result<()> {
        let conn = self.conn();
        conn.execute(
            "UPDATE meetings SET summary_json = ?2, summary_status = 'done' WHERE id = ?1",
            params![id, serde_json::to_string(summary)?],
        )?;
        conn.execute(
            "UPDATE meetings_fts SET summary = ?2 WHERE meeting_id = ?1",
            params![id, summary.searchable_text()],
        )?;
        Ok(())
    }

    // --- segments -------------------------------------------------------

    pub fn insert_segment(
        &self,
        meeting_id: i64,
        speaker: &str,
        start_ms: i64,
        end_ms: i64,
        text: &str,
    ) -> Result<Segment> {
        let conn = self.conn();
        conn.execute(
            "INSERT INTO segments(meeting_id, speaker, start_ms, end_ms, text) VALUES (?1, ?2, ?3, ?4, ?5)",
            params![meeting_id, speaker, start_ms, end_ms, text],
        )?;
        Ok(Segment {
            id: conn.last_insert_rowid(),
            meeting_id,
            speaker: speaker.into(),
            start_ms,
            end_ms,
            text: text.into(),
        })
    }

    pub fn segments(&self, meeting_id: i64) -> Result<Vec<Segment>> {
        let conn = self.conn();
        let mut stmt = conn.prepare(
            "SELECT id, meeting_id, speaker, start_ms, end_ms, text FROM segments
             WHERE meeting_id = ?1 ORDER BY start_ms, id",
        )?;
        let rows = stmt.query_map([meeting_id], |r| {
            Ok(Segment {
                id: r.get(0)?,
                meeting_id: r.get(1)?,
                speaker: r.get(2)?,
                start_ms: r.get(3)?,
                end_ms: r.get(4)?,
                text: r.get(5)?,
            })
        })?;
        Ok(rows.collect::<rusqlite::Result<_>>()?)
    }

    // --- search ---------------------------------------------------------

    pub fn search(&self, input: &str) -> Result<Vec<SearchHit>> {
        let Some(q) = fts_query(input) else {
            return Ok(vec![]);
        };
        let conn = self.conn();
        let mut hits = Vec::new();

        let mut stmt = conn.prepare(
            "SELECT m.id, m.title, m.started_at, s.id, s.speaker, s.start_ms,
                    snippet(segments_fts, 0, ?2, ?3, '…', 16)
             FROM segments_fts
             JOIN segments s ON s.id = segments_fts.rowid
             JOIN meetings m ON m.id = s.meeting_id
             WHERE segments_fts MATCH ?1
             ORDER BY rank LIMIT 200",
        )?;
        let rows = stmt.query_map(params![q, HL_START, HL_END], |r| {
            Ok(SearchHit {
                meeting_id: r.get(0)?,
                meeting_title: r.get(1)?,
                started_at: r.get(2)?,
                kind: "transcript".into(),
                segment_id: Some(r.get(3)?),
                speaker: Some(r.get(4)?),
                start_ms: Some(r.get(5)?),
                snippet: r.get(6)?,
            })
        })?;
        for row in rows {
            hits.push(row?);
        }

        let mut stmt = conn.prepare(
            "SELECT m.id, m.title, m.started_at,
                    snippet(meetings_fts, -1, ?2, ?3, '…', 16)
             FROM meetings_fts
             JOIN meetings m ON m.id = meetings_fts.meeting_id
             WHERE meetings_fts MATCH ?1
             ORDER BY rank LIMIT 50",
        )?;
        let rows = stmt.query_map(params![q, HL_START, HL_END], |r| {
            Ok(SearchHit {
                meeting_id: r.get(0)?,
                meeting_title: r.get(1)?,
                started_at: r.get(2)?,
                kind: "summary".into(),
                segment_id: None,
                speaker: None,
                start_ms: None,
                snippet: r.get(3)?,
            })
        })?;
        let mut summary_hits = rows.collect::<rusqlite::Result<Vec<_>>>()?;
        summary_hits.append(&mut hits);
        Ok(summary_hits)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::llm::{ActionItem, Summary};

    #[test]
    fn fts_query_quotes_words() {
        assert_eq!(fts_query("  "), None);
        assert_eq!(fts_query("budget q3"), Some("\"budget\" \"q3\"*".into()));
        assert_eq!(fts_query("AND \"OR\" (x"), Some("\"AND\" \"OR\" \"(x\"*".into()));
    }

    #[test]
    fn meeting_lifecycle_and_search() {
        let db = Db::open_in_memory().unwrap();
        let id = db.create_meeting("Weekly sync", "2026-10-27T10:00:00Z").unwrap();
        db.insert_segment(id, "Me", 0, 2000, "Let's review the quarterly budget").unwrap();
        db.insert_segment(id, "Them", 2500, 5000, "Marketing spend went up").unwrap();
        db.end_meeting(id, "2026-10-27T10:30:00Z").unwrap();

        let m = db.get_meeting(id).unwrap().unwrap();
        assert_eq!(m.segment_count, 2);
        assert_eq!(m.duration_ms, 5000);

        // Prefix match + porter stemming.
        let hits = db.search("budg").unwrap();
        assert_eq!(hits.len(), 1);
        assert_eq!(hits[0].speaker.as_deref(), Some("Me"));
        assert!(hits[0].snippet.contains(HL_START));
        assert_eq!(db.search("spending").unwrap().len(), 1);

        // Hostile input must not error.
        assert!(db.search("\"unbalanced (AND OR").unwrap().is_empty());

        db.save_summary(
            id,
            &Summary {
                summary: "Discussed hiring a designer".into(),
                decisions: vec![],
                action_items: vec![ActionItem { text: "Post job ad".into(), owner: None, done: false }],
            },
        )
        .unwrap();
        let hits = db.search("designer").unwrap();
        assert_eq!(hits.len(), 1);
        assert_eq!(hits[0].kind, "summary");

        db.rename_meeting(id, "Budget review").unwrap();
        assert_eq!(db.search("review").unwrap()[0].kind, "summary");

        db.delete_meeting(id).unwrap();
        assert!(db.list_meetings().unwrap().is_empty());
        assert!(db.search("budget").unwrap().is_empty());
    }

    #[test]
    fn settings_roundtrip() {
        let db = Db::open_in_memory().unwrap();
        let mut s = db.settings().unwrap();
        assert_eq!(s.whisper_model, "base.en");
        s.keep_audio = true;
        db.save_settings(&s).unwrap();
        assert!(db.settings().unwrap().keep_audio);
    }
}
