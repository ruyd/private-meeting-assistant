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

    /// Rewrites the meeting's transcript.md and summary.md (recreating its folder if it went missing).
    /// Returns the folder.
    @discardableResult
    func writeFiles(_ id: Int64) -> URL? {
        guard let store else { return nil }
        do {
            guard let meeting = try store.meeting(id) else { return nil }
            try FileManager.default.createDirectory(at: meeting.folder, withIntermediateDirectories: true)
            try MeetingFiles.write(meeting, store.segments(of: id), to: meeting.folder)
            return meeting.folder
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
            if let meeting = try store.meeting(id), FileManager.default.fileExists(atPath: meeting.folder.path) {
                try store.setFolder(id, MeetingFiles.renameFolder(meeting.folder, title: title, startedAt: meeting.startedAt))
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

    // MARK: Summaries

    static let autoSummarizeKey = "autoSummarize"
    static let summaryEngineKey = "summaryEngine"
    static let summaryModelKey = "summaryModel"

    static var summaryModel: String {
        UserDefaults.standard.string(forKey: summaryModelKey) ?? SummaryEngine.recommendedModel.name
    }

    /// Writes the meeting's summary with the engine and model chosen in Settings, saving it to the index
    /// and summary.md. Progress and errors show up as the meeting's summary status.
    func summarize(_ id: Int64) async {
        guard let store else { return }
        try? store.setSummaryStatus(id, "running")
        refresh()
        do {
            let model = Self.summaryModel
            let choice = SummaryEngine.Choice(rawValue: UserDefaults.standard.string(forKey: Self.summaryEngineKey) ?? "") ?? .automatic
            let url = try await SummaryEngine.shared.endpoint(choice: choice, model: model)
            let summary = try await Summarizer(baseURL: url, model: model).summarize(store.segments(of: id))
            try store.saveSummary(id, summary)
            writeFiles(id)
        } catch {
            log.error("summary failed: \(error.localizedDescription, privacy: .public)")
            try? store.setSummaryStatus(id, "error: \(error.localizedDescription)")
        }
        refresh()
    }

    func setActionItem(_ id: Int64, index: Int, done: Bool) {
        guard let store, var summary = (try? store.meeting(id))?.summary, summary.actionItems.indices.contains(index) else { return }
        summary.actionItems[index].done = done
        do {
            try store.saveSummary(id, summary)
        } catch {
            self.error = error.localizedDescription
        }
        writeFiles(id)
        refresh()
    }

    /// Opens the meeting's folder in Finder, with transcript.md selected.
    func showInFinder(_ id: Int64) {
        guard let folder = writeFiles(id) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([folder.appending(path: MeetingFiles.transcriptFile)])
    }
}
