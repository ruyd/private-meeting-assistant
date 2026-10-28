import AppKit
import SwiftUI

struct RecordView: View {
    let recorder: Recorder
    @Environment(AppNavigation.self) private var navigation
    @AppStorage("micDeviceUID") private var savedMicUID = ""
    @AppStorage(SettingsKeys.speechModel) private var modelID = SpeechModel.recommended.id
    @AppStorage(SettingsKeys.language) private var language = "auto"
    @AppStorage(SettingsKeys.removeEcho) private var removeEcho = true
    @State private var title = ""
    @State private var apps: [(target: SystemAudioTarget, isPlaying: Bool)] = []
    @State private var devices: [InputDevice] = []
    /// Shown before recording starts, e.g. the lid is closed and the built-in mic is selected.
    @State private var preflightIssue: MicIssue?
    private let store = ModelStore.shared

    private var session: CaptureSession { recorder.capture }
    private var model: SpeechModel { SpeechModel.find(modelID) ?? .recommended }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding()
            Divider()
            TranscriptView(recorder: recorder)
        }
        .navigationTitle("Record")
        .toolbar {
            ToolbarItem {
                Button("Copy Transcript", systemImage: "doc.on.doc") {
                    copy(TranscriptExport.plainText(recorder.lines.map { ($0.source, $0.startMs, $0.text) }))
                }
                .disabled(recorder.lines.isEmpty)
                .help("Copy the transcript as text")
            }
        }
        .task { await refreshSources() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Meeting title", text: $title, prompt: Text(Self.defaultTitle()))
                .textFieldStyle(.roundedBorder)
                .font(.title3)
                .frame(maxWidth: 480)
                .disabled(recorder.phase != .idle)
            HStack(spacing: 16) {
                recordButton
                if let startedAt = recorder.startedAt {
                    TimelineView(.periodic(from: startedAt, by: 1)) { context in
                        Text(Duration.seconds(context.date.timeIntervalSince(startedAt)).formatted(.time(pattern: .hourMinuteSecond)))
                            .font(.title3.monospacedDigit())
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    LevelRow(label: "Me", color: .blue, value: session.levels[.mic] ?? 0)
                    LevelRow(label: "Them", color: .orange, value: session.levels[.system] ?? 0)
                }
            }

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text("Microphone").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                    Picker("Microphone", selection: micSelection) {
                        Text("System default (\(InputDevices.systemDefault(among: devices)?.name ?? "none"))").tag("")
                        if !devices.isEmpty { Divider() }
                        ForEach(devices) { device in Text(device.name).tag(device.uid) }
                        if !savedMicUID.isEmpty, !devices.contains(where: { $0.uid == savedMicUID }) {
                            Text("Disconnected microphone").tag(savedMicUID)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 320)
                }
                GridRow {
                    Text("Other participants").foregroundStyle(.secondary)
                    Picker("Other participants", selection: Bindable(session).target) {
                        Text(SystemAudioTarget.allExceptThisApp.label).tag(SystemAudioTarget.allExceptThisApp)
                        if !apps.isEmpty { Divider() }
                        ForEach(apps, id: \.target) { app in
                            Text(app.isPlaying ? "\(app.target.label) (playing)" : app.target.label).tag(app.target)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 320)
                    .disabled(recorder.phase != .idle)
                }
            }

            notices
        }
    }

    @ViewBuilder private var recordButton: some View {
        switch recorder.phase {
        case .idle:
            Button {
                let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
                Task {
                    await recorder.start(
                        title: name.isEmpty ? Self.defaultTitle() : name, model: model,
                        language: language == "auto" ? nil : language, removeEcho: removeEcho
                    )
                }
            } label: {
                Label("Record", systemImage: "record.circle")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(.red)
            .disabled(!store.downloaded.contains(model.id))
        case .loadingModel:
            ProgressView().controlSize(.small)
            Text("Loading \(model.name)… The first time can take a minute or two.").foregroundStyle(.secondary)
        case .recording:
            Button {
                Task {
                    await recorder.stop()
                    title = ""
                }
            } label: {
                Label("Stop", systemImage: "stop.circle")
            }
            .controlSize(.large)
        case .finishing:
            ProgressView().controlSize(.small)
            Text("Finishing the transcript…").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var notices: some View {
        if recorder.phase == .idle, let id = recorder.meetingID, !recorder.lines.isEmpty {
            HStack {
                Label("Saved to Meetings.", systemImage: "checkmark.circle").foregroundStyle(.secondary)
                Button("Open Meeting") { navigation.open(MeetingRoute(meetingID: id)) }
            }
        }
        if !store.downloaded.contains(model.id) {
            ModelDownloadRow(model: model)
        }
        if let issue = session.micIssue ?? (recorder.phase == .idle ? preflightIssue : nil) {
            MicIssueRow(issue: issue) { micSelection.wrappedValue = $0.uid }
        }
        if let error = recorder.error ?? session.error {
            Label(error, systemImage: "exclamationmark.octagon").foregroundStyle(.red)
        }
        ForEach(session.warnings, id: \.self) { warning in
            Label(warning, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
        }
    }

    static func defaultTitle(_ date: Date = Date()) -> String {
        "Meeting \(date.formatted(.dateTime.month(.abbreviated).day().hour().minute()))"
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
            if recorder.phase == .idle {
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
}

private struct TranscriptView: View {
    let recorder: Recorder

    var body: some View {
        if recorder.lines.isEmpty && recorder.phase == .idle {
            ContentUnavailableView(
                "Ready to record",
                systemImage: "waveform",
                description: Text("What you say appears as “Me”, and the other participants as “Them”. Everything stays on this Mac.")
            )
            .frame(maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(recorder.lines) { line in
                            TranscriptRow(line: line)
                        }
                        status.id("bottom")
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: recorder.lines.count) {
                    withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
        }
    }

    @ViewBuilder private var status: some View {
        let text: String? = switch recorder.phase {
        case .recording: recorder.backlog > 1 ? "Transcribing… (\(recorder.backlog) waiting)" : "Listening…"
        case .finishing: "Finishing the transcript…"
        default: nil
        }
        if let text {
            Text(text).font(.callout).foregroundStyle(.tertiary)
        }
    }
}

/// One transcript line: time, speaker and text.
struct TranscriptRow: View {
    let source: AudioSource
    let startMs: Int
    let text: String
    var isFocused = false

    init(line: TranscriptLine) {
        self.init(source: line.source, startMs: line.startMs, text: line.text)
    }

    init(source: AudioSource, startMs: Int, text: String, isFocused: Bool = false) {
        self.source = source
        self.startMs = startMs
        self.text = text
        self.isFocused = isFocused
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(TranscriptExport.timestamp(startMs))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .trailing)
            Text(source.speaker)
                .font(.callout.bold())
                .foregroundStyle(source == .mic ? .blue : .orange)
                .frame(width: 44, alignment: .leading)
            Text(text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, isFocused ? 4 : 0)
        .background(isFocused ? Color.yellow.opacity(0.25) : .clear, in: .rect(cornerRadius: 4))
    }
}

/// Offers to download the selected model, with progress and the free-space check.
struct ModelDownloadRow: View {
    let model: SpeechModel
    private let store = ModelStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let progress = store.progress[model.id] {
                HStack {
                    ProgressView(value: progress).frame(maxWidth: 240)
                    Text("Downloading \(model.name)… \(Int(progress * 100))%").foregroundStyle(.secondary)
                    Button("Cancel") { store.cancel(model) }
                }
            } else {
                HStack {
                    Label("Transcription needs a speech model.", systemImage: "arrow.down.circle")
                    Button("Download \(model.name) (\(model.megabytes) MB)") { store.download(model) }
                }
                Text("Downloaded once from Hugging Face, then everything runs on this Mac. Each hour of meeting then adds about 1 MB of transcript.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let error = store.error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
        }
    }
}

private struct MicIssueRow: View {
    let issue: MicIssue
    let use: (InputDevice) -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Label(issue.message, systemImage: "mic.slash").foregroundStyle(.orange)
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
        HStack(spacing: 8) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(color).frame(width: geo.size.width * CGFloat(value))
                }
            }
            .frame(width: 140, height: 6)
            .animation(.linear(duration: 0.1), value: value)
        }
    }
}

func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}
