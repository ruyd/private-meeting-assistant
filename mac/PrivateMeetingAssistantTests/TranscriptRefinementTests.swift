import AppKit
import Foundation
import Testing
@testable import Private_Meeting_Assistant

struct MeetingNotesTests {
    @Test func notesAreSavedSearchableAndWrittenToNotesMd() throws {
        let store = try MeetingStore.inMemory()
        let folder = FileManager.default.temporaryDirectory.appending(path: "notes-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let id = try store.createMeeting(title: "Pricing", startedAt: Date(), folder: folder)

        try store.saveNotes(id, "Ask Priya about the enterprise tier.\nFollow up on Thursday.")
        let meeting = try #require(try store.meeting(id))
        #expect(meeting.notes.hasPrefix("Ask Priya"))
        #expect(try store.search("enterprise").contains { $0.meetingID == id && $0.kind == .titleOrSummary })

        try MeetingFiles.write(meeting, [], to: folder)
        let notes = try String(contentsOf: folder.appending(path: MeetingFiles.notesFile), encoding: .utf8)
        #expect(notes == "# Pricing: notes\n\nAsk Priya about the enterprise tier.\nFollow up on Thursday.\n")

        // Cleared notes remove the file.
        try store.saveNotes(id, "  ")
        try MeetingFiles.write(try #require(try store.meeting(id)), [], to: folder)
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: MeetingFiles.notesFile).path))
    }

    @MainActor @Test func renamingWhileRecordingKeepsTheFolderUntilAskedToMoveIt() throws {
        let store = try MeetingStore.inMemory()
        let root = FileManager.default.temporaryDirectory.appending(path: "rename-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let started = Date()
        let folder = try MeetingFiles.createFolder(in: root, title: "Meeting", startedAt: started)
        let id = try store.createMeeting(title: "Meeting", startedAt: started, folder: folder)
        let library = MeetingLibrary(store: store)

        library.rename(id, to: "Board prep", moveFolder: false)
        #expect(try store.meeting(id)?.title == "Board prep")
        #expect(try store.meeting(id)?.folder == folder)

        library.rename(id, to: "Board prep")
        let moved = try #require(try store.meeting(id)?.folder)
        #expect(moved.lastPathComponent.hasPrefix("Board prep - "))
        #expect(FileManager.default.fileExists(atPath: moved.path))
    }
}

@MainActor
struct TranscriptTextTests {
    @Test func oneTextWithEveryLineInOrder() throws {
        let segments = [
            Segment(id: 1, meetingID: 1, source: .system, startMs: 1_000, endMs: 3_000, text: "Revenue grew by twelve percent.", participant: 1, speaker: "Priya"),
            Segment(id: 2, meetingID: 1, source: .mic, startMs: 4_000, endMs: 6_000, text: "Great, let's ship on Monday.", speaker: "Me"),
        ]
        let video = MeetingScreenshot(url: URL(fileURLWithPath: "/tmp/v/00.00.03.mp4"), atMs: 3_500)
        let (text, ranges) = TranscriptTextView(segments: segments, videos: [video], fontSize: 14).build()
        let plain = text.string
        // Copying any span gives readable lines: time, speaker, text.
        // (The video has no still here, so it's a "▶︎ Video" link, then the folder icon.)
        #expect(plain == "00:01\tPriya\tRevenue grew by twelve percent.\n00:03\t\t▶︎ Video  \u{FFFC}\n00:04\tMe\tGreat, let's ship on Monday.\n")
        let second = try #require(ranges[2])
        #expect((plain as NSString).substring(with: second) == "00:04\tMe\tGreat, let's ship on Monday.\n")
        // The time links to the audio, the video to its file.
        #expect(text.attribute(.link, at: second.location, effectiveRange: nil) as? URL == URL(string: "pma-seek:4000"))
        let videoAt = (plain as NSString).range(of: "▶︎ Video").location
        #expect(text.attribute(.link, at: videoAt, effectiveRange: nil) as? URL == video.url)
        #expect(text.attribute(TranscriptTextView.openKey, at: videoAt, effectiveRange: nil) as? URL == video.url)
        // The folder icon shows it in Finder.
        let folderAt = (plain as NSString).range(of: "\u{FFFC}").location
        #expect(text.attribute(TranscriptTextView.revealKey, at: folderAt, effectiveRange: nil) as? URL == video.url)
    }
}
