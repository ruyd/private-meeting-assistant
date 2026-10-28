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

    /// What uninstalling moves to the Trash (existing items only). Meetings live in the folder the user
    /// chose, which is only included without `keepMeetings`.
    static func items(keepMeetings: Bool) -> [Item] {
        var items = [
            Item(url: ModelStore.dataFolder, label: "Speech models, the meetings index and other downloads"),
            Item(url: URL.cachesDirectory.appending(path: "dev.ruy.private-meeting-assistant"), label: "Caches"),
        ]
        if !keepMeetings, let root = MeetingFiles.root {
            items.append(Item(url: root, label: "Your meetings folder (\(MeetingFiles.displayPath(root)))"))
        }
        items.append(Item(url: Bundle.main.bundleURL, label: "The app"))
        return items.filter { FileManager.default.fileExists(atPath: $0.url.path) }
    }

    /// Moves everything to the Trash, forgets settings and permissions, then quits.
    static func run(keepMeetings: Bool) throws {
        for item in items(keepMeetings: keepMeetings) {
            try FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
        }
        if let id = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: id)
            #if !APPSTORE
            // Forget the Microphone and System Audio Recording permissions granted to this app.
            let reset = Process()
            reset.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            reset.arguments = ["reset", "All", id]
            try? reset.run()
            reset.waitUntilExit()
            #endif
        }
        NSApp.terminate(nil)
    }
}
