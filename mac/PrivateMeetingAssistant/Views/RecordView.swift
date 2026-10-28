import AppKit
import SwiftUI

struct RecordView: View {
    @AppStorage("micDeviceUID") private var savedMicUID = ""
    @State private var session = CaptureSession()
    @State private var apps: [(target: SystemAudioTarget, isPlaying: Bool)] = []
    @State private var devices: [InputDevice] = []
    /// Shown before recording starts, e.g. the lid is closed and the built-in mic is selected.
    @State private var preflightIssue: MicIssue?

    var body: some View {
        Form {
            Section {
                Picker("Microphone", selection: micSelection) {
                    Text("System default (\(InputDevices.systemDefault(among: devices)?.name ?? "none"))").tag("")
                    if !devices.isEmpty { Divider() }
                    ForEach(devices) { device in Text(device.name).tag(device.uid) }
                    if !savedMicUID.isEmpty, !devices.contains(where: { $0.uid == savedMicUID }) {
                        Text("Disconnected microphone").tag(savedMicUID)
                    }
                }
                if let issue = session.micIssue ?? (session.state == .idle ? preflightIssue : nil) {
                    MicIssueRow(issue: issue) { micSelection.wrappedValue = $0.uid }
                }
                Picker("Other participants", selection: $session.target) {
                    Text(SystemAudioTarget.allExceptThisApp.label).tag(SystemAudioTarget.allExceptThisApp)
                    if !apps.isEmpty { Divider() }
                    ForEach(apps, id: \.target) { app in
                        Text(app.isPlaying ? "\(app.target.label) (playing)" : app.target.label).tag(app.target)
                    }
                }
                .disabled(session.state != .idle)
            } header: {
                Text("Sources")
            } footer: {
                Text("Your microphone is recorded as “Me”. Choose your call app for “Them” to keep notifications and music out of the transcript.")
            }

            Section("Levels") {
                LevelRow(label: "Me", color: .blue, value: session.levels[.mic] ?? 0)
                LevelRow(label: "Them", color: .orange, value: session.levels[.system] ?? 0)
            }

            Section {
                HStack {
                    switch session.state {
                    case .idle:
                        Button("Start Audio Check") { Task { await session.start() } }
                            .buttonStyle(.borderedProminent)
                    case .starting:
                        ProgressView().controlSize(.small)
                        Text("Starting…").foregroundStyle(.secondary)
                    case .running:
                        Button("Stop") { session.stop() }
                    }
                    Spacer()
                }
                if let error = session.error {
                    Label(error, systemImage: "exclamationmark.octagon").foregroundStyle(.red)
                }
                ForEach(session.warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
            } footer: {
                Text("Transcription arrives in the next milestone. For now this checks that both sources are heard.")
            }

            Section("Permissions") {
                LabeledContent("Microphone") {
                    HStack {
                        Text(micPermissionText).foregroundStyle(.secondary)
                        if session.micPermission == .denied || session.micPermission == .restricted {
                            Button("Open Settings") { openPrivacyPane("Privacy_Microphone") }
                        }
                    }
                }
                LabeledContent("System audio") {
                    Button("Open Settings") { openPrivacyPane("Privacy_ScreenCapture") }
                }
                Text("macOS asks the first time. If “Them” stays flat while audio is playing, allow this app under **System Audio Recording Only**.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Record")
        .task { await refreshSources() }
        .onDisappear { session.stop() }
    }

    private var micPermissionText: String {
        switch session.micPermission {
        case .authorized: "Allowed"
        case .denied: "Denied"
        case .restricted: "Blocked by a device policy"
        case .notDetermined: "Not asked yet"
        @unknown default: "Unknown"
        }
    }

    /// The picker's choice, saved across launches; "" follows the system default.
    private var micSelection: Binding<String> {
        Binding(
            get: { savedMicUID },
            set: { uid in
                savedMicUID = uid
                session.selectMic(uid: uid.isEmpty ? nil : uid)
                refreshPreflightIssue()
            }
        )
    }

    private func refreshPreflightIssue() {
        let device = InputDevices.effective(chosenUID: session.micDeviceUID, among: devices)
        preflightIssue = MicIssue.lidClosed(using: device, among: devices)
    }

    /// Keeps the device and app lists current (devices get plugged in, apps start playing).
    private func refreshSources() async {
        session.selectMic(uid: savedMicUID.isEmpty ? nil : savedMicUID)
        while !Task.isCancelled {
            devices = InputDevices.all()
            refreshPreflightIssue()
            if session.state == .idle {
                var list = SystemAudioCapture.audioApps()
                // Keep the current choice selectable even if that app went quiet or quit.
                if case .app = session.target, !list.contains(where: { $0.target == session.target }) {
                    list.append((session.target, false))
                }
                apps = list
            }
            try? await Task.sleep(for: .seconds(3))
        }
    }

    private func openPrivacyPane(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}

private struct MicIssueRow: View {
    let issue: MicIssue
    let use: (InputDevice) -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Label(issue.message, systemImage: "mic.slash").foregroundStyle(.orange)
            Spacer()
            if let suggestion = issue.suggestion {
                Button("Use \(suggestion.name)") { use(suggestion) }
            }
        }
    }
}

private struct LevelRow: View {
    let label: String
    let color: Color
    let value: Float

    var body: some View {
        LabeledContent(label) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(color).frame(width: geo.size.width * CGFloat(value))
                }
            }
            .frame(width: 240, height: 8)
            .animation(.linear(duration: 0.1), value: value)
        }
    }
}
