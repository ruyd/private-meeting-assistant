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
                SettingsView()
            }
        }
    }
}
