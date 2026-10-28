import Foundation
import Observation
import OSLog

private let log = Logger(subsystem: "dev.ruy.private-meeting-assistant", category: "library")

/// The app's meeting archive, observed by the UI: the store plus the current list of meetings.
@MainActor @Observable
final class MeetingLibrary {
    static let shared = MeetingLibrary()

    /// nil if the database couldn't be opened; `error` says why.
    @ObservationIgnored let store: MeetingStore?
    private(set) var meetings: [Meeting] = []
    private(set) var error: String?

    init(store: MeetingStore? = nil) {
        do {
            self.store = try store ?? MeetingStore.open()
        } catch {
            log.error("couldn't open the meeting database: \(error.localizedDescription, privacy: .public)")
            self.store = nil
            self.error = "Couldn't open the meeting archive: \(error.localizedDescription)"
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

    func rename(_ id: Int64, to title: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        perform { try $0.renameMeeting(id, to: title) }
    }

    func delete(_ id: Int64) {
        perform { store in
            if let audio = try store.deleteMeeting(id) {
                // Only remove folders inside the app's own audio folder.
                let folder = URL(fileURLWithPath: audio).standardizedFileURL
                if folder.path.hasPrefix(ModelStore.dataFolder.appending(path: "audio").path + "/") {
                    try? FileManager.default.removeItem(at: folder)
                }
            }
        }
    }

    private func perform(_ change: (MeetingStore) throws -> Void) {
        guard let store else { return }
        do {
            try change(store)
        } catch {
            self.error = error.localizedDescription
        }
        refresh()
    }
}
