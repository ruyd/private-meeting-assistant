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

struct ContentView: View {
    @State private var section: SidebarItem? = .record

    var body: some View {
        NavigationSplitView {
            List(SidebarItem.allCases, selection: $section) { s in
                Label(s.title, systemImage: s.symbol)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            switch section ?? .record {
            case .record:
                RecordView()
            case .meetings:
                ContentUnavailableView(
                    "No meetings yet",
                    systemImage: "list.bullet.rectangle",
                    description: Text("Recorded meetings and search will appear here.")
                )
            case .settings:
                AboutView()
            }
        }
    }
}

private struct AboutView: View {
    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    var body: some View {
        Form {
            LabeledContent("Version", value: version)
            LabeledContent("Privacy", value: "Audio and transcripts stay on this Mac.")
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
    }
}
