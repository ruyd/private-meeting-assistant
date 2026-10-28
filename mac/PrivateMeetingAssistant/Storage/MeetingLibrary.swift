import AppKit
import Observation
import OSLog

private let log = Logger(subsystem: "dev.ruy.private-meeting-assistant", category: "library")

/// The app's meetings, observed by the UI: the index (`MeetingStore`), the current list, and each
/// meeting's folder of files (`MeetingFiles`), kept in step.
@MainActor @Observable
final class MeetingLibrary {
    static let shared = MeetingLibrary()

    /// nil if the index couldn't be opened; `error` says why.
    @ObservationIgnored let store: MeetingStore?
    private(set) var meetings: [Meeting] = []
    private(set) var error: String?

    init(store: MeetingStore? = nil) {
        do {
            self.store = try store ?? MeetingStore.open()
        } catch {
            log.error("couldn't open the meeting index: \(error.localizedDescription, privacy: .public)")
            self.store = nil
            self.error = "Couldn't open the meetings index: \(error.localizedDescription)"
        }
        refresh()
    }

    func refresh() {
        guard let store else { return }
        do {
            meetings = try store.meetings()
        } catch {
            self.error = "Couldn't read meetings: \(error.localizedDescription)"
        }
    }

    /// Rewrites the meeting's transcript.md and summary.md. A meeting without a folder (recorded before
    /// folders) gets one in the meetings folder, if one is chosen. Returns the folder.
    @discardableResult
    func writeFiles(_ id: Int64) -> URL? {
        guard let store else { return nil }
        do {
            guard var meeting = try store.meeting(id) else { return nil }
            if meeting.folder == nil || !FileManager.default.fileExists(atPath: meeting.folder!.path) {
                guard let root = MeetingFiles.root else { return nil }
                meeting.folder = try MeetingFiles.createFolder(in: root, title: meeting.title, startedAt: meeting.startedAt)
                try store.setFolder(id, meeting.folder)
            }
            guard let folder = meeting.folder else { return nil }
            try MeetingFiles.write(meeting, store.segments(of: id), to: folder)
            return folder
        } catch {
            self.error = "Couldn't save the meeting's files: \(error.localizedDescription)"
            return nil
        }
    }

    func rename(_ id: Int64, to title: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, let store else { return }
        do {
            try store.renameMeeting(id, to: title)
            if let meeting = try store.meeting(id), let folder = meeting.folder, FileManager.default.fileExists(atPath: folder.path) {
                try store.setFolder(id, MeetingFiles.renameFolder(folder, title: title, startedAt: meeting.startedAt))
            }
        } catch {
            self.error = "Couldn't rename: \(error.localizedDescription)"
        }
        writeFiles(id)
        refresh()
    }

    /// Removes the meeting from the index and moves its folder to the Trash.
    func delete(_ id: Int64) {
        guard let store else { return }
        do {
            let folder = try store.meeting(id)?.folder
            try store.deleteMeeting(id)
            if let folder, FileManager.default.fileExists(atPath: folder.path) {
                try FileManager.default.trashItem(at: folder, resultingItemURL: nil)
            }
        } catch {
            self.error = "Couldn't delete: \(error.localizedDescription)"
        }
        refresh()
    }

    /// Opens the meeting's folder in Finder, creating it first for meetings recorded before folders.
    func showInFinder(_ id: Int64) {
        guard let folder = writeFiles(id) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([folder.appending(path: MeetingFiles.transcriptFile)])
    }
}
