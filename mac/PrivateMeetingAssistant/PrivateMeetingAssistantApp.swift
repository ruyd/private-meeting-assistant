import SwiftUI

@main
struct PrivateMeetingAssistantApp: App {
    #if DEBUG
    @NSApplicationDelegateAdaptor private var delegate: DebugAppDelegate
    #endif

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 800, minHeight: 560)
        }
        .defaultSize(width: 1100, height: 760)
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
