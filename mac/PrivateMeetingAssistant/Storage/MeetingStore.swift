import Foundation
import GRDB

struct Meeting: Identifiable, Hashable, Sendable {
    let id: Int64
    var title: String
    let startedAt: Date
    var endedAt: Date?
    var summary: MeetingSummary?
    var summaryStatus: String
    var segmentCount: Int
    /// End of the last transcript line, in milliseconds from the start.
    var durationMs: Int
}

struct Segment: Identifiable, Hashable, Sendable {
    let id: Int64
    let meetingID: Int64
    let source: AudioSource
    let startMs: Int
    let endMs: Int
    let text: String
}

struct SearchHit: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable { case transcript, titleOrSummary }

    let meetingID: Int64
    let meetingTitle: String
    let startedAt: Date
    let kind: Kind
    let segmentID: Int64?
    let source: AudioSource?
    let startMs: Int?
    /// Matched text, with each match between `MeetingStore.highlightStart` and `highlightEnd`.
    let snippet: String

    var id: String { "\(meetingID)-\(segmentID.map(String.init) ?? "meeting")" }
}

/// The meeting archive: a SQLite database with full-text search. Same schema and file as the Tauri
/// prototype, so meetings recorded there show up here.
final class MeetingStore: Sendable {
    /// Mark highlighted matches in search snippets: control characters, so nothing needs escaping.
    static let highlightStart = "\u{1}"
    static let highlightEnd = "\u{2}"

    private let db: DatabaseQueue

    /// In the app's data folder, which needs no permission prompt. On uninstall the user can keep a
    /// copy in Documents (`keptCopyFolder`).
    static var defaultURL: URL { ModelStore.dataFolder.appending(path: "meetings.sqlite") }
    static var keptCopyFolder: URL { URL.documentsDirectory.appending(path: "Private Meeting Assistant", directoryHint: .isDirectory) }

    static func open(at url: URL = defaultURL) throws -> MeetingStore {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return try MeetingStore(db: DatabaseQueue(path: url.path))
    }

    static func inMemory() throws -> MeetingStore {
        try MeetingStore(db: DatabaseQueue())
    }

    private init(db: DatabaseQueue) throws {
        self.db = db
        try db.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
        }
        try db.write { db in
            try db.execute(sql: Self.schema)
            // A recording that was running when the app quit is left without an end time; close it so it
            // doesn't look live forever. A summary that was being written was interrupted.
            try db.execute(sql: "UPDATE meetings SET ended_at = started_at WHERE ended_at IS NULL")
            try db.execute(sql: "UPDATE meetings SET summary_status = 'none' WHERE summary_status = 'running'")
        }
    }

    /// Writes a self-contained copy of the whole archive to `url` (which must not exist), consistent
    /// even while recording.
    func backUp(to url: URL) throws {
        try db.writeWithoutTransaction { db in
            try db.execute(sql: "VACUUM INTO ?", arguments: [url.path])
        }
    }

    // MARK: Meetings

    func createMeeting(title: String, startedAt: Date) throws -> Int64 {
        try db.write { db in
            try db.execute(sql: "INSERT INTO meetings (title, started_at) VALUES (?, ?)", arguments: [title, Self.timestamp(startedAt)])
            let id = db.lastInsertedRowID
            try db.execute(sql: "INSERT INTO meetings_fts (meeting_id, title, summary) VALUES (?, ?, '')", arguments: [id, title])
            return id
        }
    }

    func endMeeting(_ id: Int64, at endedAt: Date) throws {
        try db.write { db in
            try db.execute(sql: "UPDATE meetings SET ended_at = ? WHERE id = ?", arguments: [Self.timestamp(endedAt), id])
        }
    }

    func renameMeeting(_ id: Int64, to title: String) throws {
        try db.write { db in
            try db.execute(sql: "UPDATE meetings SET title = ? WHERE id = ?", arguments: [title, id])
            try db.execute(sql: "UPDATE meetings_fts SET title = ? WHERE meeting_id = ?", arguments: [title, id])
        }
    }

    /// Deletes the meeting and its transcript. Returns its audio folder, if it kept one, for the caller to remove.
    @discardableResult
    func deleteMeeting(_ id: Int64) throws -> String? {
        try db.write { db in
            let audio = try String.fetchOne(db, sql: "SELECT audio_dir FROM meetings WHERE id = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM meetings WHERE id = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM meetings_fts WHERE meeting_id = ?", arguments: [id])
            return audio
        }
    }

    func meetings() throws -> [Meeting] {
        try db.read { db in
            try Row.fetchAll(db, sql: "SELECT \(Self.meetingColumns) FROM meetings m ORDER BY m.started_at DESC, m.id DESC")
                .map(Self.meeting)
        }
    }

    func meeting(_ id: Int64) throws -> Meeting? {
        try db.read { db in
            try Row.fetchOne(db, sql: "SELECT \(Self.meetingColumns) FROM meetings m WHERE m.id = ?", arguments: [id])
                .map(Self.meeting)
        }
    }

    // MARK: Transcript

    func insertSegment(meetingID: Int64, source: AudioSource, startMs: Int, endMs: Int, text: String) throws -> Int64 {
        try db.write { db in
            try db.execute(
                sql: "INSERT INTO segments (meeting_id, speaker, start_ms, end_ms, text) VALUES (?, ?, ?, ?, ?)",
                arguments: [meetingID, source.speaker, startMs, endMs, text]
            )
            return db.lastInsertedRowID
        }
    }

    func deleteSegment(_ id: Int64) throws {
        try db.write { db in
            try db.execute(sql: "DELETE FROM segments WHERE id = ?", arguments: [id])
        }
    }

    func segments(of meetingID: Int64) throws -> [Segment] {
        try db.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT id, meeting_id, speaker, start_ms, end_ms, text FROM segments WHERE meeting_id = ? ORDER BY start_ms, id",
                arguments: [meetingID]
            ).map { row in
                Segment(
                    id: row[0], meetingID: row[1], source: row[2] == "Me" ? .mic : .system,
                    startMs: row[3], endMs: row[4], text: row[5]
                )
            }
        }
    }

    // MARK: Search

    /// Searches transcripts, titles and summaries. Matches on titles and summaries come first.
    func search(_ input: String) throws -> [SearchHit] {
        guard let query = Self.ftsQuery(input) else { return [] }
        return try db.read { db in
            let meetingHits = try Row.fetchAll(
                db,
                sql: """
                SELECT m.id, m.title, m.started_at, snippet(meetings_fts, -1, ?, ?, '…', 16)
                FROM meetings_fts JOIN meetings m ON m.id = meetings_fts.meeting_id
                WHERE meetings_fts MATCH ? ORDER BY rank LIMIT 50
                """,
                arguments: [Self.highlightStart, Self.highlightEnd, query]
            ).map { row in
                SearchHit(
                    meetingID: row[0], meetingTitle: row[1], startedAt: Self.date(row[2]), kind: .titleOrSummary,
                    segmentID: nil, source: nil, startMs: nil, snippet: row[3]
                )
            }
            let segmentHits = try Row.fetchAll(
                db,
                sql: """
                SELECT m.id, m.title, m.started_at, s.id, s.speaker, s.start_ms,
                       snippet(segments_fts, 0, ?, ?, '…', 16)
                FROM segments_fts
                JOIN segments s ON s.id = segments_fts.rowid
                JOIN meetings m ON m.id = s.meeting_id
                WHERE segments_fts MATCH ? ORDER BY rank LIMIT 200
                """,
                arguments: [Self.highlightStart, Self.highlightEnd, query]
            ).map { row in
                SearchHit(
                    meetingID: row[0], meetingTitle: row[1], startedAt: Self.date(row[2]), kind: .transcript,
                    segmentID: row[3], source: row[4] == "Me" ? .mic : .system, startMs: row[5], snippet: row[6]
                )
            }
            return meetingHits + segmentHits
        }
    }

    /// Turns what someone typed into an FTS5 query: every word quoted (so punctuation and operators
    /// can't break the syntax), the last one a prefix, for search as you type.
    static func ftsQuery(_ input: String) -> String? {
        let words = input.split(whereSeparator: \.isWhitespace)
            .map { $0.replacingOccurrences(of: "\"", with: "") }
            .filter { !$0.isEmpty }
        guard !words.isEmpty else { return nil }
        return words.map { "\"\($0)\"" }.joined(separator: " ") + "*"
    }

    // MARK: Rows

    private static let meetingColumns = """
        m.id, m.title, m.started_at, m.ended_at, m.summary_json, m.summary_status,
        (SELECT COUNT(*) FROM segments s WHERE s.meeting_id = m.id),
        COALESCE((SELECT MAX(end_ms) FROM segments s WHERE s.meeting_id = m.id), 0)
        """

    private static func meeting(_ row: Row) -> Meeting {
        let json: String? = row[4]
        return Meeting(
            id: row[0], title: row[1], startedAt: date(row[2]), endedAt: (row[3] as String?).map(date),
            summary: json.flatMap { try? JSONDecoder().decode(MeetingSummary.self, from: Data($0.utf8)) },
            summaryStatus: row[5], segmentCount: row[6], durationMs: row[7]
        )
    }

    /// RFC 3339 timestamps, as the prototype stored them.
    static func timestamp(_ date: Date) -> String {
        date.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true).timeZone(separator: .omitted))
    }

    static func date(_ text: String) -> Date {
        (try? Date(text, strategy: .iso8601.year().month().day().time(includingFractionalSeconds: true)))
            ?? (try? Date(text, strategy: .iso8601))
            ?? ISO8601DateFormatter().date(from: text)
            ?? .distantPast
    }

    // The prototype's schema (src-tauri/src/db/schema.sql), unchanged.
    private static let schema = """
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

        CREATE VIRTUAL TABLE IF NOT EXISTS segments_fts USING fts5(
            text, content='segments', content_rowid='id', tokenize='porter unicode61'
        );
        CREATE TRIGGER IF NOT EXISTS segments_ai AFTER INSERT ON segments BEGIN
            INSERT INTO segments_fts(rowid, text) VALUES (new.id, new.text);
        END;
        CREATE TRIGGER IF NOT EXISTS segments_ad AFTER DELETE ON segments BEGIN
            INSERT INTO segments_fts(segments_fts, rowid, text) VALUES ('delete', old.id, old.text);
        END;

        CREATE VIRTUAL TABLE IF NOT EXISTS meetings_fts USING fts5(
            meeting_id UNINDEXED, title, summary, tokenize='porter unicode61'
        );

        CREATE TABLE IF NOT EXISTS settings (
            key   TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        """
}
