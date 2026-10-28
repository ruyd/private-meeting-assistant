import SwiftUI

/// Opens a meeting, optionally scrolled to one transcript line.
struct MeetingRoute: Hashable {
    let meetingID: Int64
    var focusSegmentID: Int64?
}

/// What the right half of the window shows: the recording panel or a meeting from the list.
@MainActor @Observable
final class AppNavigation {
    enum Selection: Hashable {
        case recorder
        case meeting(MeetingRoute)
    }

    var selection: Selection? = .recorder

    func open(_ route: MeetingRoute) { selection = .meeting(route) }

    func showRecorder() { selection = .recorder }
}

struct ContentView: View {
    @State private var navigation = AppNavigation()
    /// Lives here, not in the Record page, so recording continues while you browse other pages.
    @State private var recorder = Recorder()
    @AppStorage(SetupView.completedKey) private var setupCompleted = false
    @State private var showSetup = false

    var body: some View {
        NavigationSplitView {
            MeetingsView(recorder: recorder)
                .navigationSplitViewColumnWidth(min: 320, ideal: 460, max: 680)
        } detail: {
            Group {
                switch navigation.selection ?? .recorder {
                case .recorder:
                    RecordView(recorder: recorder)
                case .meeting(let route):
                    MeetingView(route: route).id(route)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Under the title bar too, so it matches.
            .background(Theme.canvas, ignoresSafeAreaEdges: .all)
        }
        .toolbar {
            ToolbarItem {
                SettingsLink { Label("Settings", systemImage: "gearshape") }
                    .help("Speech model, language, summaries and the meetings folder")
            }
        }
        .environment(navigation)
        .environment(MeetingLibrary.shared)
        .onAppear { if !setupCompleted { showSetup = true } }
        .sheet(isPresented: $showSetup) {
            SetupView {
                setupCompleted = true
                showSetup = false
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: SetupView.reopen)) { _ in showSetup = true }
    }
}
