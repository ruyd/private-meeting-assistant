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
    @AppStorage(SettingsKeys.speechModel) private var modelID = SpeechModel.recommended.id
    @State private var showSetup = false
    @AppStorage(SettingsKeys.identifySpeakers) private var identifySpeakers = true

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
        // Loads the chosen speech model in the background (again when it changes or finishes
        // downloading), so Start Recording begins right away. While a summary is being written the
        // speech model is freed instead: both together can use more memory than a 16 GB Mac has.
        // (An automatic summary starts while the recording is still finishing, so idling counts too.)
        .task(id: "\(modelID) \(ModelStore.shared.downloaded.contains(modelID)) \(MeetingLibrary.shared.summariesRunning > 0) \(recorder.phase == .idle)") {
            if MeetingLibrary.shared.summariesRunning > 0 {
                recorder.unloadModel()
            } else if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
                // Not when hosting tests: they end with exit() mid-load, which aborts in ggml.
                await recorder.preload(SpeechModel.find(modelID) ?? .recommended)
            }
        }
        .sheet(isPresented: $showSetup) {
            SetupView {
                setupCompleted = true
                showSetup = false
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: SetupView.reopen)) { _ in showSetup = true }
        // The speaker model is small; fetch it in the background so it's there for the next recording.
        .task(id: identifySpeakers) {
            if identifySpeakers { await VoiceprintStore.shared.downloadIfNeeded() }
        }
    }
}
