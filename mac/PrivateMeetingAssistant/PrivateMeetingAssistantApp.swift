import SwiftUI

@main
struct PrivateMeetingAssistantApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 900, minHeight: 600)
        }
        .defaultSize(width: 1280, height: 820)

        Settings {
            SettingsView()
                .frame(width: 640, height: 620)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        // Starts the command-line self-test at launch, independent of whether a window is shown.
        Task { @MainActor in
            WindowSnapshots.startIfRequested()
            await CaptureSelfTest.runIfRequested()
        }
        #endif
    }

    /// Quitting while the speech model loads (it starts loading at launch) waits for the load to
    /// finish: a model half-loaded onto the GPU can't be freed, and ggml aborts at exit if it isn't.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard Transcriber.isLoading else { return .terminateNow }
        Task { @MainActor in
            await Transcriber.waitForLoads()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
