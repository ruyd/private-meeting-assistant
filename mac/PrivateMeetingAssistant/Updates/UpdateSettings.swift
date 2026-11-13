#if !APPSTORE
import SwiftUI

/// Settings › About › Updates: the daily check, and checking or installing now.
struct UpdateSettingsSection: View {
    @AppStorage(Updater.autoCheckKey) private var autoCheck = true
    private let updater = Updater.shared
    private let activity = RecordingActivity.shared

    var body: some View {
        Section {
            Toggle(isOn: $autoCheck) {
                Text("Check for updates automatically")
                Text("Once a day, asks GitHub whether a newer version is out. Nothing about you or your meetings is sent.")
            }
            LabeledContent {
                action
            } label: {
                Text(title)
                if let detail { Text(detail) }
            }
        } header: {
            Text("Updates")
        }
    }

    private var title: String {
        switch updater.status {
        case .idle: "Version \(Updater.currentVersion)"
        case .checking: "Checking…"
        case .upToDate: "Up to date"
        case .available(let release): "Version \(release.version) is available"
        case .downloading(let release, _): "Downloading \(release.version)…"
        case .installing(let release): "Installing \(release.version)…"
        case .failed: "Couldn't check for updates"
        }
    }

    private var detail: String? {
        switch updater.status {
        case .idle, .upToDate:
            updater.lastChecked.map { "Last checked \($0.formatted(.relative(presentation: .named)))." }
        case .available:
            activity.isRecording
                ? "Installing relaunches the app: it can wait until the recording ends."
                : "Installing replaces this copy and relaunches it; your meetings and settings stay."
        case .failed(let message):
            message
        case .checking, .downloading, .installing:
            nil
        }
    }

    @ViewBuilder private var action: some View {
        switch updater.status {
        case .checking, .installing:
            ProgressView().controlSize(.small)
        case .downloading(_, let fraction):
            ProgressView(value: fraction).frame(width: 120)
        case .available(let release):
            HStack {
                Link("Release Notes", destination: release.page)
                Button("Install") { Task { await updater.install(release) } }
                    .disabled(activity.isRecording)
            }
        case .idle, .upToDate, .failed:
            Button("Check Now") { Task { await updater.check(userInitiated: false) } }
        }
    }
}
#endif
