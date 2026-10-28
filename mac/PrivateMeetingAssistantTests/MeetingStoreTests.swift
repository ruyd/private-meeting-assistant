import Foundation
import Testing
@testable import Private_Meeting_Assistant

struct MeetingStoreTests {
    @Test func ftsQueryQuotesWords() {
        #expect(MeetingStore.ftsQuery("  ") == nil)
        #expect(MeetingStore.ftsQuery("pricing deck") == "\"pricing\" \"deck\"*")
        #expect(MeetingStore.ftsQuery("say \"hi\" OR -x") == "\"say\" \"hi\" \"OR\" \"-x\"*")
    }

    @Test func meetingLifecycleAndSearch() throws {
        let store = try MeetingStore.inMemory()
        let start = Date(timeIntervalSince1970: 1_793_000_000)
        let id = try store.createMeeting(title: "Pricing sync", startedAt: start)
        _ = try store.insertSegment(meetingID: id, source: .system, startMs: 1_000, endMs: 3_000, text: "Priya will send the updated pricing deck.")
        let mine = try store.insertSegment(meetingID: id, source: .mic, startMs: 4_000, endMs: 6_500, text: "Let's move the launch review to Thursday.")
        try store.endMeeting(id, at: start.addingTimeInterval(10))

        let meeting = try #require(try store.meeting(id))
        #expect(meeting.title == "Pricing sync")
        #expect(abs(meeting.startedAt.timeIntervalSince(start)) < 0.01)
        #expect(meeting.segmentCount == 2)
        #expect(meeting.durationMs == 6_500)

        // Prefix search, stemming, and highlighted snippets.
        let hits = try store.search("launch revi")
        let hit = try #require(hits.first { $0.kind == .transcript })
        #expect(hit.segmentID == mine && hit.source == .mic && hit.startMs == 4_000)
        #expect(hit.snippet.contains(MeetingStore.highlightStart + "launch" + MeetingStore.highlightEnd))
        #expect(try store.search("pricing").contains { $0.kind == .titleOrSummary })

        // Renaming updates title search; deleting a line removes it from search.
        try store.renameMeeting(id, to: "Launch planning")
        #expect(try store.search("planning").contains { $0.kind == .titleOrSummary && $0.meetingID == id })
        try store.deleteSegment(mine)
        #expect(try store.search("thursday").isEmpty)

        // Deleting the meeting removes its transcript and its search entries.
        try store.deleteMeeting(id)
        #expect(try store.meetings().isEmpty)
        #expect(try store.search("priya").isEmpty)
        #expect(try store.search("planning").isEmpty)
    }

    @Test func backUpWritesACompleteCopy() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try MeetingStore.open(at: dir.appending(path: "meetings.sqlite"))
        let id = try store.createMeeting(title: "Kept", startedAt: Date())
        _ = try store.insertSegment(meetingID: id, source: .mic, startMs: 0, endMs: 1_000, text: "Remember the budget review.")

        let copyURL = dir.appending(path: "copy.sqlite")
        try store.backUp(to: copyURL)
        let copy = try MeetingStore.open(at: copyURL)
        #expect(try copy.meetings().map(\.title) == ["Kept"])
        #expect(try copy.search("budget").count == 1)
    }

    @Test func meetingFolderFiles() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var date = DateComponents(calendar: .current, year: 2026, month: 10, day: 28, hour: 14, minute: 30).date!
        #expect(MeetingFiles.folderName(title: "Q4: plan/review", startedAt: date) == "Q4- plan-review - 2026-10-28 14.30")

        // Same subject and minute: the second folder gets a number instead of overwriting.
        let first = try MeetingFiles.createFolder(in: root, title: "Sync", startedAt: date)
        let second = try MeetingFiles.createFolder(in: root, title: "Sync", startedAt: date)
        #expect(first.lastPathComponent == "Sync - 2026-10-28 14.30")
        #expect(second.lastPathComponent == "Sync - 2026-10-28 14.30 (2)")

        var meeting = Meeting(
            id: 1, title: "Sync", startedAt: date, endedAt: nil,
            summary: MeetingSummary(summary: "We met.", decisions: ["Ship it"], actionItems: [.init(text: "Write docs", owner: "Me", done: true)]),
            summaryStatus: "done", segmentCount: 1, durationMs: 61_000, folder: first
        )
        try MeetingFiles.write(meeting, [Segment(id: 1, meetingID: 1, source: .system, startMs: 61_000, endMs: 62_000, text: "Hi")], to: first)
        let transcript = try String(contentsOf: first.appending(path: "transcript.md"), encoding: .utf8)
        #expect(transcript.contains("# Sync") && transcript.contains("2 min") && transcript.contains("**[01:01] Them:** Hi"))
        let summary = try String(contentsOf: first.appending(path: "summary.md"), encoding: .utf8)
        #expect(summary.contains("We met.") && summary.contains("- [x] Write docs — *Me*"))

        // Renaming keeps the date; a removed summary removes summary.md.
        let renamed = try MeetingFiles.renameFolder(first, title: "Launch", startedAt: date)
        #expect(renamed.lastPathComponent == "Launch - 2026-10-28 14.30")
        meeting.summary = nil
        try MeetingFiles.write(meeting, [], to: renamed)
        #expect(!FileManager.default.fileExists(atPath: renamed.appending(path: "summary.md").path))
        date = date.addingTimeInterval(0)
        #expect(TranscriptExport.fileName("../..") == "-")
    }

    /// Opens a copy of the prototype's database, if this Mac has one, to check the schemas match.
    @Test(.enabled(if: FileManager.default.fileExists(atPath: MeetingStore.defaultURL.path)))
    func readsThePrototypeDatabase() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for suffix in ["", "-wal", "-shm"] {
            let source = URL(fileURLWithPath: MeetingStore.defaultURL.path + suffix)
            if FileManager.default.fileExists(atPath: source.path) {
                try FileManager.default.copyItem(at: source, to: dir.appending(path: "meetings.sqlite" + suffix))
            }
        }
        let store = try MeetingStore.open(at: dir.appending(path: "meetings.sqlite"))
        let meetings = try store.meetings()
        #expect(meetings.allSatisfy { $0.startedAt != .distantPast })
        for m in meetings where m.summaryStatus == "done" {
            #expect(m.summary != nil, "summary of meeting \(m.id) didn't decode")
        }
        print("prototype database: \(meetings.count) meetings, \(meetings.map(\.segmentCount).reduce(0, +)) lines")
    }
}
