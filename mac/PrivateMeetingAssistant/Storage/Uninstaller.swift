import AppKit

/// Removes the app and what it downloaded. macOS gives apps no hook when they're dragged to the Trash,
/// so this runs from Settings instead. Everything goes to the Trash, so it can still be recovered.
@MainActor
enum Uninstaller {
    struct Item: Identifiable {
        let url: URL
        let label: String
        var id: URL { url }
    }

    static let keepMeetingsKey = "keepMeetingsOnUninstall"

    /// What uninstalling moves to the Trash (existing items only). The app's data folder holds the
    /// meetings, so with `keepMeetings` they're copied to Documents first.
    static func items(keepMeetings: Bool) -> [Item] {
        [
            Item(url: ModelStore.dataFolder, label: keepMeetings
                ? "Speech models and other downloads (your meetings are copied to Documents first)"
                : "Your meetings, speech models and other downloads"),
            Item(url: URL.cachesDirectory.appending(path: "dev.ruy.private-meeting-assistant"), label: "Caches"),
            Item(url: Bundle.main.bundleURL, label: "The app"),
        ].filter { FileManager.default.fileExists(atPath: $0.url.path) }
    }

    /// Where the kept copy goes: Documents › Private Meeting Assistant › meetings.sqlite, or a dated name
    /// if a copy from an earlier uninstall is already there.
    static func keptCopyURL(now: Date = Date()) -> URL {
        let folder = MeetingStore.keptCopyFolder
        let plain = folder.appending(path: "meetings.sqlite")
        guard FileManager.default.fileExists(atPath: plain.path) else { return plain }
        let stamp = now.formatted(.iso8601.year().month().day().dateSeparator(.dash).time(includingFractionalSeconds: false).timeSeparator(.omitted))
        return folder.appending(path: "meetings \(stamp).sqlite")
    }

    /// Keeps a copy of the meetings if asked, moves everything to the Trash, forgets settings and
    /// permissions, then quits. Stops before deleting anything if the copy fails.
    static func run(keepMeetings: Bool, store: MeetingStore?) throws {
        if keepMeetings, let store {
            try FileManager.default.createDirectory(at: MeetingStore.keptCopyFolder, withIntermediateDirectories: true)
            try store.backUp(to: keptCopyURL())
        }
        for item in items(keepMeetings: keepMeetings) {
            try FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
        }
        if let id = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: id)
            // Forget the Microphone and System Audio Recording permissions granted to this app.
            let reset = Process()
            reset.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            reset.arguments = ["reset", "All", id]
            try? reset.run()
            reset.waitUntilExit()
        }
        NSApp.terminate(nil)
    }
}
