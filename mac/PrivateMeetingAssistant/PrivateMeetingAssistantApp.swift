import SwiftUI

@main
struct PrivateMeetingAssistantApp: App {
    #if DEBUG
    @NSApplicationDelegateAdaptor private var delegate: DebugAppDelegate
    #endif

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

#if DEBUG
/// Starts the command-line self-test at launch, independent of whether a window is shown.
final class DebugAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in await CaptureSelfTest.runIfRequested() }
    }
}
#endif
