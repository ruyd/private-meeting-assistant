PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS meetings (
    id             INTEGER PRIMARY KEY AUTOINCREMENT,
    title          TEXT    NOT NULL,
    started_at     TEXT    NOT NULL,
    ended_at       TEXT,
    audio_dir      TEXT,
    summary_json   TEXT,
    summary_status TEXT    NOT NULL DEFAULT 'none'
);

CREATE TABLE IF NOT EXISTS segments (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    meeting_id INTEGER NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
    speaker    TEXT    NOT NULL,
    start_ms   INTEGER NOT NULL,
    end_ms     INTEGER NOT NULL,
    text       TEXT    NOT NULL
);
CREATE INDEX IF NOT EXISTS segments_meeting ON segments(meeting_id, start_ms);

-- Full-text index over transcript text, kept in sync by triggers.
CREATE VIRTUAL TABLE IF NOT EXISTS segments_fts USING fts5(
    text, content='segments', content_rowid='id', tokenize='porter unicode61'
);
CREATE TRIGGER IF NOT EXISTS segments_ai AFTER INSERT ON segments BEGIN
    INSERT INTO segments_fts(rowid, text) VALUES (new.id, new.text);
END;
CREATE TRIGGER IF NOT EXISTS segments_ad AFTER DELETE ON segments BEGIN
    INSERT INTO segments_fts(segments_fts, rowid, text) VALUES ('delete', old.id, old.text);
END;

-- Title + summary text per meeting; maintained from Rust.
CREATE VIRTUAL TABLE IF NOT EXISTS meetings_fts USING fts5(
    meeting_id UNINDEXED, title, summary, tokenize='porter unicode61'
);

CREATE TABLE IF NOT EXISTS settings (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
);
