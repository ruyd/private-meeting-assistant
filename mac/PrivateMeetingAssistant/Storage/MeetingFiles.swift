import Foundation

/// Meetings as plain files people can open, share and back up: one folder per meeting inside the
/// folder they chose, named "<Subject> - <date time>", with transcript.md and, once there is one,
/// summary.md. Screenshots and video recordings will go into the same folder. The database is only
/// an index for the meetings list and search.
enum MeetingFiles {
    static let rootKey = "meetingsFolder"
    static let transcriptFile = "transcript.md"
    static let summaryFile = "summary.md"

    /// The folder chosen in setup or Settings; nil until chosen.
    static var root: URL? {
        get { UserDefaults.standard.string(forKey: rootKey).map { URL(fileURLWithPath: $0, isDirectory: true) } }
        set { UserDefaults.standard.set(newValue?.path, forKey: rootKey) }
    }

    /// Suggested in setup: ~/Meetings. Unlike Documents or Desktop, macOS doesn't ask permission for it.
    static var suggestedRoot: URL { URL.homeDirectory.appending(path: "Meetings", directoryHint: .isDirectory) }

    /// "Pricing sync - 2026-10-28 14.30": readable, sorts by subject, and the time tells apart two
    /// meetings with the same subject on one day.
    static func folderName(title: String, startedAt: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: startedAt)
        let date = String(format: "%04d-%02d-%02d %02d.%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0)
        return "\(TranscriptExport.fileName(title)) - \(date)"
    }

    /// Creates the meeting's folder under `root`, adding " (2)", " (3)"… if the name is taken.
    static func createFolder(in root: URL, title: String, startedAt: Date) throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let base = folderName(title: title, startedAt: startedAt)
        var url = root.appending(path: base, directoryHint: .isDirectory)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = root.appending(path: "\(base) (\(n))", directoryHint: .isDirectory)
            n += 1
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    /// Renames the folder for a new title, keeping its date. Returns the new location.
    static func renameFolder(_ folder: URL, title: String, startedAt: Date) throws -> URL {
        let parent = folder.deletingLastPathComponent()
        let base = folderName(title: title, startedAt: startedAt)
        var target = parent.appending(path: base, directoryHint: .isDirectory)
        var n = 2
        while FileManager.default.fileExists(atPath: target.path), target.standardizedFileURL != folder.standardizedFileURL {
            target = parent.appending(path: "\(base) (\(n))", directoryHint: .isDirectory)
            n += 1
        }
        guard target.standardizedFileURL != folder.standardizedFileURL else { return folder }
        try FileManager.default.moveItem(at: folder, to: target)
        return target
    }

    /// Writes transcript.md, and summary.md if the meeting has a summary (removing a stale one if not).
    static func write(_ meeting: Meeting, _ segments: [Segment], to folder: URL) throws {
        try transcriptMarkdown(meeting, segments).write(to: folder.appending(path: transcriptFile), atomically: true, encoding: .utf8)
        let summaryURL = folder.appending(path: summaryFile)
        if let summary = meeting.summary {
            try summaryMarkdown(meeting, summary).write(to: summaryURL, atomically: true, encoding: .utf8)
        } else if FileManager.default.fileExists(atPath: summaryURL.path) {
            try FileManager.default.removeItem(at: summaryURL)
        }
    }

    static func transcriptMarkdown(_ meeting: Meeting, _ segments: [Segment]) -> String {
        var out = "# \(meeting.title)\n\n*\(heading(meeting))*\n\n"
        for s in segments {
            out += "**[\(TranscriptExport.timestamp(s.startMs))] \(s.source.speaker):** \(s.text)\n\n"
        }
        return out
    }

    static func summaryMarkdown(_ meeting: Meeting, _ s: MeetingSummary) -> String {
        var out = "# \(meeting.title)\n\n*\(heading(meeting))*\n\n## Summary\n\n\(s.summary.trimmingCharacters(in: .whitespacesAndNewlines))\n\n"
        if !s.decisions.isEmpty {
            out += "## Decisions\n\n" + s.decisions.map { "- \($0)\n" }.joined() + "\n"
        }
        if !s.actionItems.isEmpty {
            out += "## Action items\n\n" + s.actionItems.map { a in
                "- [\(a.done ? "x" : " ")] \(a.text)\(a.owner.map { " — *\($0)*" } ?? "")\n"
            }.joined() + "\n"
        }
        return out
    }

    private static func heading(_ meeting: Meeting) -> String {
        let date = meeting.startedAt.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().year().hour().minute())
        return "\(date) · \((meeting.durationMs + 59_999) / 60_000) min"
    }
}
