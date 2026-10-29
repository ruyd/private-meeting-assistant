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
    /// The meeting's folder of files: transcript.md, summary.md, and later screenshots and video.
    var folder: URL
    /// Subject, schedule and participants from the linked calendar or Zoom, if the recording was
    /// started from one.
    var details: MeetingDetails? = nil
    /// Notes typed during or after the meeting (also in notes.md).
    var notes: String = ""
}

struct Segment: Identifiable, Hashable, Sendable {
    let id: Int64
    let meetingID: Int64
    let source: AudioSource
    let startMs: Int
    let endMs: Int
    let text: String
    /// The voice this line was told apart as, if speakers were identified.
    var participant: Int? = nil
    /// Who said it: the participant's name, "Participant 2", or "Me" / "Them".
    var speaker: String = ""
}

/// A voice told apart in a meeting: "Participant 2" until someone names it.
struct MeetingSpeaker: Identifiable, Hashable, Sendable {
    let number: Int
    var name: String?
    /// The line kept as a sample of this voice, in meeting milliseconds.
    let sampleStartMs: Int
    let sampleEndMs: Int
    /// Speech heard from this voice.
    let speechMs: Int

    var id: Int { number }
    var label: String { name?.nilIfBlank ?? "Participant \(number)" }
}

struct SearchHit: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable { case transcript, titleOrSummary }

    let meetingID: Int64
    let meetingTitle: String
    let startedAt: Date
    let kind: Kind
    let segmentID: Int64?
    let source: AudioSource?
    /// For transcript hits: who said it, and their participant number if speakers were identified.
    var speaker: String? = nil
    var participant: Int? = nil
    let startMs: Int?
    /// Matched text, with each match between `MeetingStore.highlightStart` and `highlightEnd`.
    let snippet: String

    var id: String { "\(meetingID)-\(segmentID.map(String.init) ?? "meeting")" }
}

/// The index of meetings: a SQLite database with full-text search, for the meetings list and search.
/// The meetings themselves are folders of Markdown files (`MeetingFiles`).
final class MeetingStore: Sendable {
    /// Mark highlighted matches in search snippets: control characters, so nothing needs escaping.
    static let highlightStart = "\u{1}"
    static let highlightEnd = "\u{2}"

    private let db: DatabaseQueue

    static var defaultURL: URL { ModelStore.dataFolder.appending(path: "index.sqlite") }

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
            try Self.migrate(db)
            // A recording that was running when the app quit is left without an end time; close it so it
            // doesn't look live forever. A summary that was being written was interrupted.
            try db.execute(sql: "UPDATE meetings SET ended_at = started_at WHERE ended_at IS NULL")
            try db.execute(sql: "UPDATE meetings SET summary_status = 'none' WHERE summary_status = 'running'")
        }
    }

    // MARK: Meetings

    func createMeeting(title: String, startedAt: Date, folder: URL, details: MeetingDetails? = nil) throws -> Int64 {
        try db.write { db in
            try db.execute(
                sql: "INSERT INTO meetings (title, started_at, folder, details_json) VALUES (?, ?, ?, ?)",
                arguments: [title, Self.timestamp(startedAt), folder.path, Self.json(details)]
            )
            let id = db.lastInsertedRowID
            try db.execute(
                sql: "INSERT INTO meetings_fts (meeting_id, title, summary, participants, notes) VALUES (?, ?, '', ?, '')",
                arguments: [id, title, Self.searchableParticipants(details)]
            )
            return id
        }
    }

    /// Attaches (or, with nil, removes) the calendar meeting a recording belongs to.
    func setDetails(_ id: Int64, _ details: MeetingDetails?) throws {
        try db.write { db in
            try db.execute(sql: "UPDATE meetings SET details_json = ? WHERE id = ?", arguments: [Self.json(details), id])
            try db.execute(
                sql: "UPDATE meetings_fts SET participants = ? WHERE meeting_id = ?",
                arguments: [Self.searchableParticipants(details), id]
            )
        }
    }

    private static func json(_ details: MeetingDetails?) -> String? {
        details.flatMap { try? JSONEncoder().encode($0) }.map { String(decoding: $0, as: UTF8.self) }
    }

    /// Names and emails, so searching for a person finds the meetings they were in.
    private static func searchableParticipants(_ details: MeetingDetails?) -> String {
        (details?.participants ?? []).map { [$0.name, $0.email].compactMap { $0 }.joined(separator: " ") }.joined(separator: "\n")
    }

    func setFolder(_ id: Int64, _ folder: URL) throws {
        try db.write { db in
            try db.execute(sql: "UPDATE meetings SET folder = ? WHERE id = ?", arguments: [folder.path, id])
        }
    }

    func endMeeting(_ id: Int64, at endedAt: Date) throws {
        try db.write { db in
            try db.execute(sql: "UPDATE meetings SET ended_at = ? WHERE id = ?", arguments: [Self.timestamp(endedAt), id])
        }
    }

    /// "none", "running", "done", or "error: <reason>".
    func setSummaryStatus(_ id: Int64, _ status: String) throws {
        try db.write { db in
            try db.execute(sql: "UPDATE meetings SET summary_status = ? WHERE id = ?", arguments: [status, id])
        }
    }

    /// Stores the summary (status "done") and indexes it for search.
    func saveSummary(_ id: Int64, _ summary: MeetingSummary) throws {
        let json = String(decoding: try JSONEncoder().encode(summary), as: UTF8.self)
        try db.write { db in
            try db.execute(sql: "UPDATE meetings SET summary_json = ?, summary_status = 'done' WHERE id = ?", arguments: [json, id])
            try db.execute(sql: "UPDATE meetings_fts SET summary = ? WHERE meeting_id = ?", arguments: [summary.searchableText, id])
        }
    }

    /// Saves the meeting's notes and indexes them for search.
    func saveNotes(_ id: Int64, _ notes: String) throws {
        try db.write { db in
            try db.execute(sql: "UPDATE meetings SET notes = ? WHERE id = ?", arguments: [notes, id])
            try db.execute(sql: "UPDATE meetings_fts SET notes = ? WHERE meeting_id = ?", arguments: [notes, id])
        }
    }

    func renameMeeting(_ id: Int64, to title: String) throws {
        try db.write { db in
            try db.execute(sql: "UPDATE meetings SET title = ? WHERE id = ?", arguments: [title, id])
            try db.execute(sql: "UPDATE meetings_fts SET title = ? WHERE meeting_id = ?", arguments: [title, id])
        }
    }

    /// Removes the meeting and its transcript from the index (its folder is the caller's business).
    func deleteMeeting(_ id: Int64) throws {
        try db.write { db in
            try db.execute(sql: "DELETE FROM meetings WHERE id = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM meetings_fts WHERE meeting_id = ?", arguments: [id])
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

    func insertSegment(meetingID: Int64, source: AudioSource, startMs: Int, endMs: Int, text: String, participant: Int? = nil) throws -> Int64 {
        try db.write { db in
            try db.execute(
                sql: "INSERT INTO segments (meeting_id, speaker, start_ms, end_ms, text, participant) VALUES (?, ?, ?, ?, ?, ?)",
                arguments: [meetingID, source.speaker, startMs, endMs, text, participant]
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
                sql: """
                SELECT s.id, s.meeting_id, s.speaker, s.start_ms, s.end_ms, s.text, s.participant, \(Self.speakerLabel)
                FROM segments s LEFT JOIN participants p ON p.meeting_id = s.meeting_id AND p.number = s.participant
                WHERE s.meeting_id = ? ORDER BY s.start_ms, s.id
                """,
                arguments: [meetingID]
            ).map { row in
                Segment(
                    id: row[0], meetingID: row[1], source: row[2] == "Me" ? .mic : .system,
                    startMs: row[3], endMs: row[4], text: row[5], participant: row[6], speaker: row[7]
                )
            }
        }
    }

    /// SQL for a line's speaker label, given segments `s` joined with participants `p`.
    private static let speakerLabel = """
        COALESCE(NULLIF(TRIM(p.name), ''), CASE WHEN s.participant IS NOT NULL THEN 'Participant ' || s.participant END, s.speaker)
        """

    // MARK: Speakers

    /// Saves the voices told apart in a recording (replacing any saved before) and which of them
    /// said each line.
    func saveSpeakers(_ meetingID: Int64, _ speakers: [MeetingSpeaker], voiceprints: [Int: [Float]], lines: [Int64: Int]) throws {
        try db.write { db in
            try db.execute(sql: "DELETE FROM participants WHERE meeting_id = ?", arguments: [meetingID])
            for s in speakers {
                let voiceprint = voiceprints[s.number].map { v in v.withUnsafeBufferPointer { Data(buffer: $0) } }
                try db.execute(
                    sql: """
                    INSERT INTO participants (meeting_id, number, name, sample_start_ms, sample_end_ms, speech_ms, voiceprint)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [meetingID, s.number, s.name, s.sampleStartMs, s.sampleEndMs, s.speechMs, voiceprint]
                )
            }
            for (segmentID, participant) in lines {
                try db.execute(sql: "UPDATE segments SET participant = ? WHERE id = ? AND meeting_id = ?", arguments: [participant, segmentID, meetingID])
            }
        }
    }

    func speakers(of meetingID: Int64) throws -> [MeetingSpeaker] {
        try db.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT number, name, sample_start_ms, sample_end_ms, speech_ms FROM participants WHERE meeting_id = ? ORDER BY number",
                arguments: [meetingID]
            ).map { row in
                MeetingSpeaker(number: row[0], name: row[1], sampleStartMs: row[2], sampleEndMs: row[3], speechMs: row[4])
            }
        }
    }

    /// Names the voices (nil or blank: back to "Participant N").
    func nameSpeakers(_ meetingID: Int64, _ names: [Int: String?]) throws {
        try db.write { db in
            for (number, name) in names {
                try db.execute(
                    sql: "UPDATE participants SET name = ? WHERE meeting_id = ? AND number = ?",
                    arguments: [name?.nilIfBlank, meetingID, number]
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
                       snippet(segments_fts, 0, ?, ?, '…', 16), s.participant, \(Self.speakerLabel)
                FROM segments_fts
                JOIN segments s ON s.id = segments_fts.rowid
                JOIN meetings m ON m.id = s.meeting_id
                LEFT JOIN participants p ON p.meeting_id = s.meeting_id AND p.number = s.participant
                WHERE segments_fts MATCH ? ORDER BY rank LIMIT 200
                """,
                arguments: [Self.highlightStart, Self.highlightEnd, query]
            ).map { row in
                SearchHit(
                    meetingID: row[0], meetingTitle: row[1], startedAt: Self.date(row[2]), kind: .transcript,
                    segmentID: row[3], source: row[4] == "Me" ? .mic : .system, speaker: row[8], participant: row[7],
                    startMs: row[5], snippet: row[6]
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
        COALESCE((SELECT MAX(end_ms) FROM segments s WHERE s.meeting_id = m.id), 0),
        m.folder, m.details_json, COALESCE(m.notes, '')
        """

    private static func meeting(_ row: Row) -> Meeting {
        let json: String? = row[4]
        return Meeting(
            id: row[0], title: row[1], startedAt: date(row[2]), endedAt: (row[3] as String?).map(date),
            summary: json.flatMap { try? JSONDecoder().decode(MeetingSummary.self, from: Data($0.utf8)) },
            summaryStatus: row[5], segmentCount: row[6], durationMs: row[7],
            folder: URL(fileURLWithPath: row[8], isDirectory: true),
            details: (row[9] as String?).flatMap { try? JSONDecoder().decode(MeetingDetails.self, from: Data($0.utf8)) },
            notes: row[10]
        )
    }

    /// ISO 8601 in UTC, which also sorts chronologically as text.
    private static let dateFormat = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    static func timestamp(_ date: Date) -> String { date.formatted(dateFormat) }

    static func date(_ text: String) -> Date { (try? Date(text, strategy: dateFormat)) ?? .distantPast }

    /// Changes to databases made by earlier versions.
    private static func migrate(_ db: Database) throws {
        if try !db.columns(in: "segments").contains(where: { $0.name == "participant" }) {
            try db.execute(sql: "ALTER TABLE segments ADD COLUMN participant INTEGER")
        }
        if try !db.columns(in: "meetings").contains(where: { $0.name == "details_json" }) {
            try db.execute(sql: "ALTER TABLE meetings ADD COLUMN details_json TEXT")
        }
        if try !db.columns(in: "meetings").contains(where: { $0.name == "notes" }) {
            try db.execute(sql: "ALTER TABLE meetings ADD COLUMN notes TEXT")
        }
        // FTS5 tables can't gain columns: rebuild the title, summary, participants and notes index
        // from the meetings when it lacks one.
        let ftsColumns = try db.columns(in: "meetings_fts").map(\.name)
        if !["participants", "notes"].allSatisfy(ftsColumns.contains) {
            try db.execute(sql: "DROP TABLE meetings_fts")
            try db.execute(sql: Self.meetingsFTS)
            for row in try Row.fetchAll(db, sql: "SELECT id, title, summary_json, details_json, COALESCE(notes, '') FROM meetings") {
                let summary = (row[2] as String?).flatMap { try? JSONDecoder().decode(MeetingSummary.self, from: Data($0.utf8)) }
                let details = (row[3] as String?).flatMap { try? JSONDecoder().decode(MeetingDetails.self, from: Data($0.utf8)) }
                try db.execute(
                    sql: "INSERT INTO meetings_fts (meeting_id, title, summary, participants, notes) VALUES (?, ?, ?, ?, ?)",
                    arguments: [row[0] as DatabaseValue, row[1] as DatabaseValue, summary?.searchableText ?? "",
                                Self.searchableParticipants(details), row[4] as DatabaseValue]
                )
            }
        }
    }

    private static let meetingsFTS = """
        CREATE VIRTUAL TABLE IF NOT EXISTS meetings_fts USING fts5(
            meeting_id UNINDEXED, title, summary, participants, notes, tokenize='porter unicode61'
        );
        """

    private static let schema = """
        CREATE TABLE IF NOT EXISTS meetings (
            id             INTEGER PRIMARY KEY AUTOINCREMENT,
            title          TEXT    NOT NULL,
            started_at     TEXT    NOT NULL,
            ended_at       TEXT,
            folder         TEXT    NOT NULL,
            summary_json   TEXT,
            summary_status TEXT    NOT NULL DEFAULT 'none',
            details_json   TEXT,
            notes          TEXT
        );

        CREATE TABLE IF NOT EXISTS segments (
            id         INTEGER PRIMARY KEY AUTOINCREMENT,
            meeting_id INTEGER NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
            speaker    TEXT    NOT NULL,
            start_ms   INTEGER NOT NULL,
            end_ms     INTEGER NOT NULL,
            text       TEXT    NOT NULL,
            -- The voice told apart as Participant N, if speakers were identified.
            participant INTEGER
        );
        CREATE INDEX IF NOT EXISTS segments_meeting ON segments(meeting_id, start_ms);

        -- Voices told apart in a meeting: a name once given, a sample line and the voiceprint.
        CREATE TABLE IF NOT EXISTS participants (
            meeting_id      INTEGER NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
            number          INTEGER NOT NULL,
            name            TEXT,
            sample_start_ms INTEGER NOT NULL,
            sample_end_ms   INTEGER NOT NULL,
            speech_ms       INTEGER NOT NULL,
            voiceprint      BLOB,
            PRIMARY KEY (meeting_id, number)
        );

        -- Transcript text, kept in sync by triggers.
        CREATE VIRTUAL TABLE IF NOT EXISTS segments_fts USING fts5(
            text, content='segments', content_rowid='id', tokenize='porter unicode61'
        );
        CREATE TRIGGER IF NOT EXISTS segments_ai AFTER INSERT ON segments BEGIN
            INSERT INTO segments_fts(rowid, text) VALUES (new.id, new.text);
        END;
        CREATE TRIGGER IF NOT EXISTS segments_ad AFTER DELETE ON segments BEGIN
            INSERT INTO segments_fts(segments_fts, rowid, text) VALUES ('delete', old.id, old.text);
        END;

        """ + "\n-- Title, summary, participants and notes per meeting, maintained by MeetingStore.\n" + meetingsFTS
}
