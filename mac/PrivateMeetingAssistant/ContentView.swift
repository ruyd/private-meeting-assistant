import SwiftUI

enum SidebarItem: String, CaseIterable, Identifiable {
    case record, meetings, settings

    var id: Self { self }

    var title: String {
        switch self {
        case .record: "Record"
        case .meetings: "Meetings"
        case .settings: "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .record: "record.circle"
        case .meetings: "list.bullet.rectangle"
        case .settings: "gearshape"
        }
    }
}

/// Opens a meeting, optionally scrolled to one transcript line.
struct MeetingRoute: Hashable {
    let meetingID: Int64
    var focusSegmentID: Int64?
}

/// Where the window is: the sidebar section and, under Meetings, the open meeting.
@MainActor @Observable
final class AppNavigation {
    var section: SidebarItem? = .record
    var meetingPath: [MeetingRoute] = []

    func open(_ route: MeetingRoute) {
        section = .meetings
        meetingPath = [route]
    }
}

struct ContentView: View {
    @State private var navigation = AppNavigation()
    /// Lives here, not in the Record page, so recording continues while you browse other pages.
    @State private var recorder = Recorder()
    @AppStorage(SetupView.completedKey) private var setupCompleted = false
    @State private var showSetup = false

    var body: some View {
        NavigationSplitView {
            List(SidebarItem.allCases, selection: $navigation.section) { s in
                HStack {
                    Label(s.title, systemImage: s.symbol)
                    if s == .record && recorder.phase == .recording {
                        Spacer()
                        Circle().fill(.red).frame(width: 8, height: 8).help("Recording")
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            switch navigation.section ?? .record {
            case .record:
                RecordView(recorder: recorder)
            case .meetings:
                NavigationStack(path: $navigation.meetingPath) {
                    MeetingsView()
                        .navigationDestination(for: MeetingRoute.self) { MeetingView(route: $0) }
                }
            case .settings:
                SettingsView()
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
