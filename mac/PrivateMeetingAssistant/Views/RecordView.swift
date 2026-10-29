import AppKit
import SwiftUI

/// The right half of the window when no meeting is open: set up a recording (microphone, the apps to
/// listen to, a name) and start it; while recording, the live transcript and actions.
struct RecordView: View {
    let recorder: Recorder

    var body: some View {
        switch recorder.phase {
        case .idle, .loadingModel: NewRecordingView(recorder: recorder)
        case .recording, .finishing: LiveRecordingView(recorder: recorder)
        }
    }

    static func defaultTitle(_ date: Date = Date()) -> String {
        "Meeting \(date.formatted(.dateTime.month(.abbreviated).day().hour().minute()))"
    }
}

// MARK: - New recording

private struct NewRecordingView: View {
    let recorder: Recorder
    @AppStorage("micDeviceUID") private var savedMicUID = ""
    @AppStorage(SettingsKeys.speechModel) private var modelID = SpeechModel.recommended.id
    @AppStorage(SettingsKeys.language) private var language = "auto"
    /// Set in Settings › Transcription › While recording.
    @AppStorage(SettingsKeys.removeEcho) private var removeEcho = true
    @AppStorage(SettingsKeys.identifySpeakers) private var identifySpeakers = true
    @AppStorage(SettingsKeys.saveAudio) private var saveAudio = true
    @AppStorage(MeetingLibrary.autoSummarizeKey) private var autoSummarize = true
    @State private var title = ""
    /// The calendar or Zoom meeting picked for this recording, with its participants.
    @State private var details: MeetingDetails?
    /// First recording: ask where meetings go before starting.
    @State private var askForFolder = false
    @State private var apps: [(target: SystemAudioTarget, isPlaying: Bool)] = []
    @State private var devices: [InputDevice] = []
    @State private var icons: [String: NSImage] = [:]
    /// Shown before recording starts, e.g. the lid is closed and the built-in mic is selected.
    @State private var preflightIssue: MicIssue?
    @State private var micTest = MicTest()
    private let store = ModelStore.shared

    private var session: CaptureSession { recorder.capture }
    private var model: SpeechModel { SpeechModel.find(modelID) ?? .recommended }

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    micRow
                    sources
                    UpcomingMeetingsSection(selected: $details) { meeting in
                        details = meeting
                        title = meeting.title
                    }
                    // The name and button sit a little above the middle of the space left.
                    Spacer(minLength: 16)
                    centre.frame(maxWidth: .infinity)
                    Spacer(minLength: 16)
                    Spacer(minLength: 0)
                    notices
                }
                .padding(.horizontal, 28)
                .padding(.top, 20)
                .padding(.bottom, 28)
                .frame(minHeight: geo.size.height)
            }
        }
        .navigationTitle("New Recording")
        .task { await refreshSources() }
        .task {
            // AppKit gives the first text field the keyboard when the window opens, which puts a
            // caret in the middle of the name's placeholder; start with nothing focused instead.
            await Task.yield()
            NSApp.keyWindow?.makeFirstResponder(nil)
        }
        .onDisappear { micTest.stop() }
        .sheet(isPresented: $askForFolder) {
            MeetingsFolderSetup { folder in
                askForFolder = false
                guard let folder else { return }
                MeetingFiles.root = folder
                startRecording()
            }
        }
    }

    // MARK: Microphone

    private var micRow: some View {
        HStack(spacing: 12) {
            Menu {
                Picker("Microphone", selection: micSelection) {
                    Text("System default (\(InputDevices.systemDefault(among: devices)?.name ?? "none"))").tag("")
                    if !devices.isEmpty { Divider() }
                    ForEach(devices) { device in Text(device.name).tag(device.uid) }
                    if !savedMicUID.isEmpty, !devices.contains(where: { $0.uid == savedMicUID }) {
                        Text("Disconnected microphone").tag(savedMicUID)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "mic")
                        .font(.system(size: 17))
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("MICROPHONE")
                            .font(.system(size: 10, weight: .semibold))
                            .tracking(0.6)
                            .foregroundStyle(.secondary)
                        Text(micName).font(.system(size: 14, weight: .medium)).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .frame(height: 56)
                .background(Theme.surface, in: .rect(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.stroke))
                .contentShape(.rect(cornerRadius: 12))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .help("Choose the microphone that records you")

            MuteButton(recorder: recorder, large: true)

            Button {
                if micTest.isRunning {
                    micTest.stop()
                } else {
                    Task { await micTest.start(deviceUID: session.micDeviceUID) }
                }
            } label: {
                LevelHistory(levels: micTest.history, isActive: micTest.isRunning)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(width: 132, height: 56)
                    .background(Theme.surface, in: .rect(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.stroke))
                    .overlay {
                        if !micTest.isRunning {
                            Text("Test mic")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(.regularMaterial, in: .capsule)
                        }
                    }
                    .contentShape(.rect(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .help(micTest.isRunning ? "Stop the microphone test" : "Listen to the microphone for 10 seconds and show its level")
            .accessibilityLabel(micTest.isRunning ? "Stop the microphone test" : "Test the microphone")
        }
    }

    /// The chosen microphone's name, or the system default's.
    private var micName: String {
        if savedMicUID.isEmpty {
            return InputDevices.systemDefault(among: devices).map { "\($0.name) (system default)" } ?? "System default"
        }
        return devices.first { $0.uid == savedMicUID }?.name ?? "Disconnected microphone"
    }

    // MARK: Sources

    private var sources: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Sources").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Text("Capture audio from the apps you pick").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            FlowLayout(spacing: 10) {
                SourceTile(
                    name: "Microphone only", detail: "In-person meeting", symbol: "mic",
                    isSelected: !session.captureSystemAudio
                ) { select(nil) }
                SourceTile(
                    name: "System audio", detail: "All apps", symbol: "speaker.wave.2",
                    isSelected: session.captureSystemAudio && session.target == .allExceptThisApp
                ) { select(.allExceptThisApp) }
                ForEach(apps, id: \.target) { app in
                    let id = app.target.bundleID ?? ""
                    SourceTile(
                        name: app.target.label, detail: SourceTile.describe(id), symbol: "app",
                        icon: icons[id], tiled: true,
                        isSelected: session.captureSystemAudio && session.target == app.target
                    ) { select(app.target) }
                }
            }
        }
    }

    /// nil records the microphone only.
    private func select(_ target: SystemAudioTarget?) {
        if let target {
            session.captureSystemAudio = true
            session.target = target
        } else {
            session.captureSystemAudio = false
        }
    }

    // MARK: Name and record button

    private var centre: some View {
        VStack(spacing: 22) {
            VStack(spacing: 8) {
                Text("Meeting name").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                TextField("Meeting name", text: $title, prompt: Text(RecordView.defaultTitle()))
                    .textFieldStyle(.plain)
                    .font(.system(size: 22, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .onSubmit(startRecording)
                    .frame(height: 40)
                Divider()
            }
            .frame(maxWidth: 520)

            if let details {
                VStack(spacing: 8) {
                    HStack(spacing: 6) {
                        Text("\(details.participants.count) participant\(details.participants.count == 1 ? "" : "s") from \(details.provider.name)")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                        Button("Detach", systemImage: "xmark.circle.fill") { self.details = nil }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                            .help("Record without this meeting's details")
                    }
                    ParticipantsList(details: details)
                }
                .frame(maxWidth: 620)
            }

            recordButton

            HStack(spacing: 8) {
                Toggle("Tell speakers apart", isOn: $identifySpeakers)
                    .help(session.captureSystemAudio
                        ? "Label each voice heard through the computer as its own participant instead of one “Them”"
                        : "Label each voice in the room as its own participant (Participant 1, 2…)")
                Toggle("Save audio", isOn: $saveAudio)
                    .help("Keep the meeting's audio (your microphone and the call) as audio.m4a in its folder; you can switch it while recording")
                Toggle("Summarize when done", isOn: $autoSummarize)
                    .help("Write a summary with a local model when the recording stops")
            }
            .toggleStyle(OptionChipStyle())

            Text("Everything stays on this Mac. Transcription runs locally.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var recordButton: some View {
        if recorder.phase == .loadingModel {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Loading \(model.name)…").foregroundStyle(.secondary)
            }
            .frame(height: 52)
        } else {
            RecordSplitButton(start: startRecording) {
                Picker("Language", selection: $language) {
                    ForEach(SettingsView.languages, id: \.code) { Text($0.name).tag($0.code) }
                }
                .pickerStyle(.menu)
                .disabled(model.englishOnly)
                Picker("Speech Model", selection: $modelID) {
                    ForEach(SpeechModel.catalog) { Text($0.name).tag($0.id) }
                }
                .pickerStyle(.menu)
                Divider()
                SettingsLink { Text("Settings…") }
            }
            .disabled(!store.downloaded.contains(model.id))
        }
    }

    private func startRecording() {
        guard recorder.phase == .idle else { return }
        guard MeetingFiles.root != nil else {
            askForFolder = true
            return
        }
        micTest.stop()
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            await recorder.start(
                title: name.isEmpty ? RecordView.defaultTitle() : name, model: model,
                language: language == "auto" ? nil : language, removeEcho: removeEcho, details: details,
                identifySpeakers: identifySpeakers, saveAudio: saveAudio
            )
        }
    }

    @ViewBuilder private var notices: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !store.downloaded.contains(model.id) {
                ModelDownloadRow(model: model)
            }
            if let issue = preflightIssue {
                MicIssueRow(issue: issue) { micSelection.wrappedValue = $0.uid }
            }
            if let error = recorder.error ?? session.error {
                Label(error, systemImage: "exclamationmark.octagon").foregroundStyle(.red)
            }
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
                // Show the new microphone's level straight away.
                Task { await micTest.start(deviceUID: session.micDeviceUID) }
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
            var list = SystemAudioCapture.audioApps()
            // Keep the current choice selectable even if that app went quiet or quit.
            if case .app = session.target, !list.contains(where: { $0.target == session.target }) {
                list.append((session.target, false))
            }
            apps = list
            for id in list.compactMap(\.target.bundleID) where icons[id] == nil { icons[id] = ScreenCapture.icon(of: id) }
            try? await Task.sleep(for: .seconds(3))
        }
    }
}

/// The red "Start recording" pill, with an arrow for the language and speech model.
private struct RecordSplitButton<Options: View>: View {
    let start: () -> Void
    @ViewBuilder let options: () -> Options
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(spacing: 0) {
            Button(action: start) {
                HStack(spacing: 10) {
                    Circle().fill(.white).frame(width: 13, height: 13)
                    Text("Start recording").font(.system(size: 15, weight: .semibold))
                }
                .padding(.leading, 22)
                .padding(.trailing, 24)
                .frame(height: 50)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("r", modifiers: .command)
            .help("Start recording (⌘R)")

            Rectangle().fill(.white.opacity(0.3)).frame(width: 1, height: 50)

            Menu(content: options) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 13, weight: .bold))
                    .frame(width: 46, height: 50)
                    .contentShape(.rect)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .background(Color.black.opacity(0.08))
            .help("Language and speech model")
            .accessibilityLabel("Recording options")
        }
        .foregroundStyle(.white)
        .background(Color.red)
        .clipShape(.capsule)
        .shadow(color: .red.opacity(isEnabled ? 0.3 : 0), radius: 14, y: 6)
        .opacity(isEnabled ? 1 : 0.45)
        .fixedSize()
    }
}

/// An on/off option as a small capsule with a dot: green when on.
private struct OptionChipStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Chip(configuration: configuration)
    }

    private struct Chip: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            let on = configuration.isOn
            Button { configuration.isOn.toggle() } label: {
                HStack(spacing: 7) {
                    Circle().fill(on ? Color.green : Color.secondary.opacity(0.5)).frame(width: 7, height: 7)
                    configuration.label
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(on ? .primary : .secondary)
                .padding(.horizontal, 14)
                .frame(height: 30)
                .background(on ? AnyShapeStyle(Theme.raised) : AnyShapeStyle(.clear), in: .capsule)
                .overlay(Capsule().strokeBorder(on ? AnyShapeStyle(.secondary.opacity(0.5)) : AnyShapeStyle(Theme.stroke)))
                .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .opacity(isEnabled ? 1 : 0.45)
            .accessibilityValue(on ? "On" : "Off")
        }
    }
}

/// One source to listen to: a tiled preview with the app's icon (or a symbol), its name and a note.
private struct SourceTile: View {
    let name: String
    let detail: String
    let symbol: String
    var icon: NSImage?
    /// The coloured-tiles backdrop, for apps with windows.
    var tiled = false
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                ZStack {
                    Rectangle().fill(Theme.raised)
                    if tiled { TiledPreview(seed: name.unicodeScalars.reduce(0) { $0 + Int($1.value) }, inset: 8) }
                    Group {
                        if let icon {
                            Image(nsImage: icon).resizable().frame(width: 32, height: 32)
                        } else {
                            Image(systemName: symbol)
                                .font(.system(size: 14, weight: .semibold))
                                .frame(width: 32, height: 32)
                                .background(.background.opacity(0.7), in: .rect(cornerRadius: 8))
                        }
                    }
                    .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
                }
                .frame(height: 72)
                .overlay(alignment: .topTrailing) {
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .red)
                            .font(.system(size: 17))
                            .padding(5)
                    }
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .padding(.bottom, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: 128)
            .background(Theme.surface)
            .clipShape(.rect(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(isSelected ? AnyShapeStyle(.red) : AnyShapeStyle(Theme.stroke), lineWidth: isSelected ? 1.5 : 1)
            }
            .contentShape(.rect(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(name), \(detail)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// What the app is usually for in a meeting; its call state isn't something the app can see.
    static func describe(_ bundleID: String) -> String {
        switch bundleID {
        case "us.zoom.xos", "com.microsoft.teams2", "com.microsoft.teams", "Cisco-Systems.Spark", "com.cisco.webexmeetingsapp":
            "Video meetings"
        case "com.tinyspeck.slackmacgap": "Huddles"
        case "com.hnc.Discord": "Voice channels"
        case "com.apple.FaceTime", "net.whatsapp.WhatsApp", "desktop.WhatsApp", "ru.keepcoder.Telegram", "com.skype.skype":
            "Calls"
        case "com.google.Chrome", "com.apple.Safari", "com.microsoft.edgemac", "company.thebrowser.Browser",
             "org.mozilla.firefox", "com.brave.Browser":
            "Browser tabs"
        case "com.spotify.client", "com.apple.Music": "Music"
        default: "App audio"
        }
    }
}

/// The stand-in for a window: a 2×2 grid of muted coloured tiles, optionally with an app badge.
struct TiledPreview: View {
    let seed: Int
    var badge: String?
    var inset: CGFloat = 4

    private static let palette: [Color] = [
        Color(red: 0.23, green: 0.29, blue: 0.42), Color(red: 0.29, green: 0.25, blue: 0.37),
        Color(red: 0.18, green: 0.32, blue: 0.29), Color(red: 0.35, green: 0.27, blue: 0.21),
        Color(red: 0.23, green: 0.25, blue: 0.29), Color(red: 0.18, green: 0.30, blue: 0.39),
    ]

    var body: some View {
        let k = abs(seed)
        ZStack(alignment: .bottomLeading) {
            Rectangle().fill(Theme.raised)
            Grid(horizontalSpacing: 3, verticalSpacing: 3) {
                GridRow { tile(k); tile(k + 1) }
                GridRow { tile(k + 2); tile(k + 3) }
            }
            .padding(inset)
            if let badge, let letter = badge.first {
                Text(String(letter))
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 16, height: 16)
                    .background(Self.palette[k % Self.palette.count].mix(with: .blue, by: 0.5), in: .rect(cornerRadius: 4))
                    .padding(inset)
            }
        }
    }

    private func tile(_ i: Int) -> some View {
        RoundedRectangle(cornerRadius: 3).fill(Self.palette[i % Self.palette.count])
    }
}

/// Lays out views left to right, wrapping onto new rows.
struct FlowLayout: Layout {
    var spacing: CGFloat = 10

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private func rows(width: CGFloat, subviews: Subviews) -> [(indices: [Int], width: CGFloat, height: CGFloat)] {
        var rows: [(indices: [Int], width: CGFloat, height: CGFloat)] = []
        var current: (indices: [Int], width: CGFloat, height: CGFloat) = ([], 0, 0)
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width, !current.indices.isEmpty {
                rows.append(current)
                current = ([index], size.width, size.height)
            } else {
                current = (current.indices + [index], needed, max(current.height, size.height))
            }
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

/// Opens the microphone for ten seconds to show its level. Only on request, so the menu-bar mic
/// indicator doesn't show just because the app is open.
@MainActor @Observable
final class MicTest {
    static let historyLength = 14

    private(set) var level: Float = 0
    /// The latest levels, oldest first, for the bar graph.
    private(set) var history = [Float](repeating: 0, count: historyLength)
    private(set) var isRunning = false
    @ObservationIgnored private var mic: MicCapture?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let meter = LevelMeter()

    func start(deviceUID: String?) async {
        stop()
        if MicCapture.permission == .notDetermined { _ = await MicCapture.requestPermission() }
        guard MicCapture.permission == .authorized else { return }
        let meter = meter
        let mic = MicCapture(deviceUID: deviceUID) { meter.record($0) }
        guard (try? mic.start()) != nil else { return }
        self.mic = mic
        isRunning = true
        task = Task { [weak self] in
            let end = Date.now.addingTimeInterval(10)
            while !Task.isCancelled, Date.now < end {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self else { return }
                self.level = meter.take()[.mic] ?? 0
                self.history = Array(self.history.dropFirst()) + [self.level]
            }
            if !Task.isCancelled { self?.stop() }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        mic?.stop()
        mic = nil
        isRunning = false
        level = 0
        history = [Float](repeating: 0, count: Self.historyLength)
    }
}

/// The last moments of input level as vertical bars, newest on the right. Idle, a dim resting shape.
private struct LevelHistory: View {
    let levels: [Float]
    let isActive: Bool

    private static let resting: [Float] = [0.3, 0.5, 0.65, 0.45, 0.75, 0.55, 0.4, 0.6, 0.5, 0.35, 0.45, 0.3, 0.22, 0.15]

    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(Array(levels.enumerated()), id: \.offset) { index, level in
                let shown = isActive ? level : Self.resting[index % Self.resting.count]
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(isActive ? (level > 0.85 ? Color.orange : Color.green) : Color.secondary.opacity(0.25))
                    .frame(maxWidth: .infinity)
                    .frame(height: max(3, 36 * CGFloat(shown)))
            }
        }
        .frame(maxHeight: .infinity, alignment: .bottom)
        .animation(.linear(duration: 0.1), value: levels)
        .accessibilityHidden(true)
    }
}

/// A segmented level meter, like the one in Sound settings: segments light up from the left, green,
/// then yellow and orange near the top.
struct LevelBars: View {
    let level: Float
    var bars = 24
    var height: CGFloat = 8

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<bars, id: \.self) { i in
                Capsule()
                    .fill(level * Float(bars) > Float(i) ? color(i) : Color.secondary.opacity(0.2))
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(height: height)
        .animation(.linear(duration: 0.08), value: level)
        .accessibilityHidden(true)
    }

    private func color(_ i: Int) -> Color {
        let position = Double(i) / Double(max(bars - 1, 1))
        return position > 0.85 ? .orange : position > 0.7 ? .yellow : .green
    }
}

// MARK: - Live recording

private struct LiveRecordingView: View {
    let recorder: Recorder
    @Environment(AppNavigation.self) private var navigation
    @Environment(MeetingLibrary.self) private var library
    @State private var appIcon: NSImage?
    @State private var micName: String?
    /// The meeting's name as typed in the header; renamed on Return or when leaving the field.
    @State private var titleDraft = ""
    @FocusState private var editingTitle: Bool

    private var session: CaptureSession { recorder.capture }

    private var title: String {
        library.meetings.first { $0.id == recorder.meetingID }?.title ?? "Recording"
    }

    private var sourceName: String {
        session.captureSystemAudio ? session.target.label : "Microphone only"
    }

    private var screenshotCaption: String {
        recorder.screenshotApp.map { "Screenshot · \($0.name)" } ?? "Screenshot"
    }

    private enum Item: Identifiable {
        case line(TranscriptLine)
        case screenshot(MeetingScreenshot)
        case video(MeetingScreenshot)

        var id: String {
            switch self {
            case .line(let line): line.id.uuidString
            case .screenshot(let shot), .video(let shot): shot.url.path
            }
        }

        var ms: Int {
            switch self {
            case .line(let line): line.startMs
            case .screenshot(let shot), .video(let shot): shot.atMs
            }
        }
    }

    /// Transcript lines with screenshots and videos placed where they were taken.
    private var items: [Item] {
        (recorder.lines.map(Item.line) + recorder.screenshots.map(Item.screenshot) + recorder.videos.map(Item.video))
            .sorted { $0.ms < $1.ms }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 28)
                .padding(.vertical, 16)
            Divider()
            transcript
            if let id = recorder.meetingID {
                NotesEditor(meetingID: id, initial: "", minHeight: 58)
                    .frame(maxHeight: 120)
                    .padding(.horizontal, 28)
                    .padding(.bottom, 12)
                    .id(id)
            }
            Divider()
            actions
                .padding(.horizontal, 28)
                .padding(.vertical, 16)
        }
        .navigationTitle(title)
        .toolbar {
            ToolbarItemGroup {
                TranscriptFontButtons()
                Button("Copy Transcript", systemImage: "doc.on.doc") {
                    copy(TranscriptExport.plainText(recorder.lines.map { ($0.speaker, $0.startMs, $0.text) }))
                }
                .disabled(recorder.lines.isEmpty)
                .help("Copy the transcript so far as text")
            }
        }
        .task {
            if session.captureSystemAudio, let id = session.target.bundleID { appIcon = ScreenCapture.icon(of: id) }
        }
        // Again whenever the microphone changes, e.g. from the lid-closed notice.
        .task(id: session.micDeviceUID) {
            micName = InputDevices.effective(chosenUID: session.micDeviceUID, among: InputDevices.all())?.name
        }
        .sheet(isPresented: Binding(
            get: { !recorder.windowChoices.isEmpty },
            set: { if !$0 { Task { await recorder.chooseWindow(nil) } } }
        )) {
            CaptureWindowPicker(appName: recorder.screenshotApp?.name ?? "the app", choices: recorder.windowChoices) { id in
                Task { await recorder.chooseWindow(id) }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                HStack(spacing: 8) {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 8))
                        .symbolEffect(.pulse)
                    Text("REC").font(.caption.weight(.bold))
                    if let startedAt = recorder.startedAt {
                        ElapsedTime(since: startedAt).font(.callout.monospacedDigit())
                    }
                }
                .foregroundStyle(.red)
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(.red.opacity(0.15), in: .capsule)

                // Renaming while recording changes the title; the folder follows when the recording stops.
                TextField("Meeting name", text: $titleDraft)
                    .textFieldStyle(.plain)
                    .font(.title2.weight(.semibold))
                    .focused($editingTitle)
                    .onSubmit { renameMeeting() }
                    .onChange(of: editingTitle) { if !editingTitle { renameMeeting() } }
                    .onChange(of: title, initial: true) { if !editingTitle { titleDraft = title } }
                    .editingOutline(editingTitle)
                    .help("Rename the meeting")
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    MeterRow(label: "Me", level: session.levels[.mic] ?? 0)
                    if session.captureSystemAudio {
                        MeterRow(label: "Them", level: session.levels[.system] ?? 0)
                    }
                }
            }
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    if let appIcon {
                        Image(nsImage: appIcon).resizable().frame(width: 18, height: 18)
                    } else {
                        Image(systemName: session.captureSystemAudio ? "speaker.wave.2" : "mic")
                    }
                    Text(sourceName)
                }
                .chipStyle()
                if let micName {
                    HStack(spacing: 6) {
                        Label(micName, systemImage: recorder.isMicMuted ? "mic.slash" : "mic")
                            .foregroundStyle(recorder.isMicMuted ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                        MuteButton(recorder: recorder, large: false)
                    }
                    .chipStyle()
                }
                Spacer()
                // As in the recording design: words as they're spoken, or only the final lines.
                Picker("Transcript", selection: Binding(
                    get: { recorder.showsLiveText },
                    set: { on in Task { await recorder.setLiveText(on) } }
                )) {
                    Text("Live").tag(true)
                    Text("Delayed").tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("Live shows words as they're spoken (on-device, then replaced by the final, more accurate line). Delayed shows only the final lines, a few seconds after each phrase.")
            }
            .font(.callout)

            if let issue = session.micIssue {
                MicIssueRow(issue: issue) { device in
                    session.selectMic(uid: device.uid)
                    // Remembered for the next recording too, as when picked on the New Recording page.
                    UserDefaults.standard.set(device.uid, forKey: "micDeviceUID")
                }
            }
            if let error = recorder.error ?? session.error {
                Label(error, systemImage: "exclamationmark.octagon").foregroundStyle(.red)
            }
            ForEach(session.warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(items) { item in
                        switch item {
                        case .line(let line):
                            SpeakerRow(
                                speaker: line.speaker, source: line.source, participant: line.participant,
                                startMs: line.startMs, text: line.text
                            )
                        case .screenshot(let shot):
                            ScreenshotRow(shot: shot, caption: screenshotCaption)
                        case .video(let video):
                            VideoRow(
                                video: video, isRecording: recorder.isRecordingVideo && video == recorder.videos.last,
                                isFinishing: recorder.finishingVideos.contains(video.url)
                            )
                        }
                    }
                    ForEach(liveSources, id: \.self) { source in
                        LiveTextRow(
                            speaker: liveSpeaker(source), source: source, text: recorder.liveText[source] ?? ""
                        )
                    }
                    status.id("bottom")
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: items.count) {
                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: recorder.liveText) {
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .overlay {
                if items.isEmpty, liveSources.isEmpty {
                    ContentUnavailableView(
                        "Listening…",
                        systemImage: "waveform",
                        description: Text(emptyDescription)
                    )
                }
            }
        }
    }

    private var emptyDescription: String {
        let timing = recorder.showsLiveText
            ? "Words appear as they're spoken, then the final line a few seconds later"
            : "Lines appear a few seconds after they're spoken"
        return recorder.identifiesSpeakers
            ? "\(timing), each voice as its own participant."
            : "\(timing): you as “Me”, the other participants as “Them”."
    }

    private func renameMeeting() {
        let name = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let id = recorder.meetingID, !name.isEmpty, name != title else {
            titleDraft = title
            return
        }
        library.rename(id, to: name, moveFolder: false)
    }

    /// Sources with words being spoken right now, mic first.
    private var liveSources: [AudioSource] {
        AudioSource.allCases.filter { recorder.liveText[$0]?.isEmpty == false && !($0 == .mic && recorder.isMicMuted) }
    }

    /// Who the live text is from, as far as is known before Whisper and the speaker model have run.
    private func liveSpeaker(_ source: AudioSource) -> String {
        if recorder.identifiesSpeakers, source == .system || !session.captureSystemAudio { return "Speaking" }
        return source.speaker
    }

    @ViewBuilder private var status: some View {
        HStack(spacing: 8) {
            if recorder.phase == .finishing || recorder.backlog > 1 {
                ProgressView().controlSize(.small)
            }
            Text(recorder.phase == .finishing
                ? "Finishing the transcript…"
                : recorder.backlog > 1 ? "Transcribing… (\(recorder.backlog) waiting)" : "Listening…")
        }
        .font(.callout)
        .foregroundStyle(.tertiary)
        .padding(.leading, 46)
    }

    /// The bar at the bottom, as in the recording design: screenshot, video, audio, then Stop.
    private var actions: some View {
        HStack(spacing: 12) {
            Button {
                Task { await recorder.takeScreenshot() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "camera")
                    Text("Screenshot")
                    if !recorder.screenshots.isEmpty {
                        Text("\(recorder.screenshots.count)").monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }
            .buttonStyle(BarButtonStyle())
            .keyboardShortcut("s", modifiers: [.command, .shift])
            .disabled(recorder.phase != .recording || recorder.isTakingScreenshot || recorder.screenshotApp == nil)
            .help(recorder.screenshotApp.map { "Save a screenshot of \($0.name)'s window in the meeting's folder (⇧⌘S)" }
                ?? "Screenshots only capture the app you're recording; pick one under Sources next time")

            VideoButton(recorder: recorder)

            Button {
                recorder.setSavingAudio(!recorder.isSavingAudio)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "waveform")
                    Text(recorder.isSavingAudio ? "Recording audio" : "Record audio")
                }
            }
            .buttonStyle(BarButtonStyle(activeTint: recorder.isSavingAudio ? .green : nil))
            .keyboardShortcut("a", modifiers: [.command, .shift])
            .disabled(recorder.phase != .recording)
            .help(recorder.isSavingAudio
                ? "Stop saving audio (⇧⌘A); the transcript goes on"
                : "Save the meeting's audio (your microphone and the call) as audio.m4a in the meeting's folder (⇧⌘A)")

            Spacer(minLength: 12)

            Button {
                Task { await stop() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "stop.fill")
                    Text("Stop")
                }
            }
            .buttonStyle(BarButtonStyle(filled: .red))
            .keyboardShortcut(".", modifiers: .command)
            .disabled(recorder.phase != .recording)
            .help("Stop recording; the meeting opens when its transcript is finished (⌘.)")
        }
    }

    /// Stops, then opens the finished meeting, unless another one was opened meanwhile.
    private func stop() async {
        await recorder.stop()
        if navigation.selection == .recorder, let id = recorder.meetingID {
            navigation.open(MeetingRoute(meetingID: id))
        }
    }
}

/// Mutes and unmutes the microphone (⇧⌘M), next to its name: before recording (to start muted)
/// and while recording.
private struct MuteButton: View {
    let recorder: Recorder
    /// The New Recording page's tile size, or a small button in the recording header's chip.
    let large: Bool

    var body: some View {
        let muted = recorder.isMicMuted
        Button {
            recorder.isMicMuted.toggle()
        } label: {
            Image(systemName: muted ? "mic.slash.fill" : "mic.fill")
                .font(.system(size: large ? 17 : 12, weight: .semibold))
                .foregroundStyle(muted ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                .frame(width: large ? 56 : 22, height: large ? 56 : 20)
                .background {
                    if large {
                        RoundedRectangle(cornerRadius: 12).fill(muted ? AnyShapeStyle(Color.red.opacity(0.12)) : AnyShapeStyle(Theme.surface))
                    } else if muted {
                        Capsule().fill(Color.red.opacity(0.15))
                    }
                }
                .overlay {
                    if large {
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(muted ? AnyShapeStyle(Color.red.opacity(0.8)) : AnyShapeStyle(Theme.stroke), lineWidth: muted ? 1.5 : 1)
                    }
                }
                .contentShape(.rect)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .keyboardShortcut("m", modifiers: [.command, .shift])
        .help(muted ? "Unmute the microphone (⇧⌘M)" : "Mute the microphone (⇧⌘M): nothing you say is transcribed or saved until you unmute")
        .accessibilityLabel(muted ? "Unmute the microphone" : "Mute the microphone")
    }
}

/// Record video, as a split button: the main part starts a video the way chosen last (the app's
/// sound, or with your microphone mixed in after echo removal; the whole window, or cut down to
/// where the video is, smaller) or stops one; the chevron picks.
private struct VideoButton: View {
    let recorder: Recorder
    @AppStorage("videoWithMic") private var withMic = false
    @AppStorage("videoCutSize") private var cutSize = false

    private var title: String {
        if recorder.isRecordingVideo { return "Recording video" }
        if recorder.isMixingVideo { return "Finishing video…" }
        return "Record video" + (withMic ? " + mic" : "") + (cutSize ? " (cut size)" : "")
    }

    var body: some View {
        let active = recorder.isRecordingVideo
        let enabled = recorder.phase == .recording && recorder.canRecordVideo && !recorder.isStartingVideo
        HStack(spacing: 0) {
            Button {
                Task { await recorder.toggleVideo(withMic: withMic, cutSize: cutSize) }
            } label: {
                HStack(spacing: 8) {
                    if recorder.isStartingVideo || recorder.isMixingVideo && !active {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: active ? "record.circle" : "video")
                            .symbolEffect(.pulse, isActive: active)
                    }
                    Text(title)
                }
                .padding(.leading, 18)
                .padding(.trailing, 12)
                .frame(maxHeight: .infinity)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("v", modifiers: [.command, .shift])
            .help(active
                ? "Stop the video (⇧⌘V); the recording goes on"
                : recorder.screenshotApp.map { app in
                    "Record \(app.name)'s window with its sound" + (withMic ? " and your voice (echo removed)" : "")
                        + (cutSize ? ", without the tabs and the page below the video, smaller" : "")
                        + ", into the meeting's folder (⇧⌘V)"
                } ?? "Video records the app you're recording; pick one under Sources next time")

            Rectangle().fill(active ? Color.red.opacity(0.5) : Theme.stroke).frame(width: 1).padding(.vertical, 10)

            Menu {
                Picker("Video sound", selection: $withMic) {
                    Text("Record video").tag(false)
                    Text("Record video + mic").tag(true)
                }
                .pickerStyle(.inline)
                Divider()
                Toggle("Cut size: without the tabs and the page below, smaller file", isOn: $cutSize)
            } label: {
                Image(systemName: "chevron.down").font(.system(size: 11, weight: .bold))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .padding(.horizontal, 12)
            .frame(maxHeight: .infinity)
            .contentShape(.rect)
            .disabled(active)
            .help("Record the app's sound only or with your microphone too, and the whole window or cut down")
        }
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(active ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
        .frame(height: 44)
        .background(active ? AnyShapeStyle(Color.red.opacity(0.12)) : AnyShapeStyle(Theme.surface), in: .rect(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(active ? AnyShapeStyle(Color.red.opacity(0.8)) : AnyShapeStyle(Theme.stroke), lineWidth: active ? 1.5 : 1)
        )
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
    }
}

/// Asks which of the recorded app's windows to capture when it isn't clear (several browser windows,
/// none of them a known call or video site): each window's picture and title.
private struct CaptureWindowPicker: View {
    let appName: String
    let choices: [CaptureWindowChoice]
    let choose: (CGWindowID?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Which \(appName) window?").font(.title3.weight(.semibold))
                Text("Screenshots and videos use it for the rest of this recording, while it's open.").foregroundStyle(.secondary)
            }
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 16)], spacing: 16) {
                    ForEach(choices) { choice in
                        Button {
                            choose(choice.id)
                        } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 8).fill(.quaternary)
                                    if let preview = choice.preview {
                                        Image(decorative: preview, scale: 1).resizable().aspectRatio(contentMode: .fit)
                                    }
                                }
                                .frame(height: 140)
                                .clipShape(.rect(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
                                Text(choice.title).font(.callout).lineLimit(2).multilineTextAlignment(.leading)
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .help("Capture this window")
                    }
                }
            }
            .frame(maxHeight: 420)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { choose(nil) }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 560)
    }
}

/// A button in the recording bar: a rounded tile on the app's surface. `activeTint` outlines and
/// colours it while what it controls is on (green while saving audio); `filled` is for Stop.
private struct BarButtonStyle: ButtonStyle {
    var activeTint: Color?
    var filled: Color?

    func makeBody(configuration: Configuration) -> some View {
        Tile(configuration: configuration, activeTint: activeTint, filled: filled)
    }

    private struct Tile: View {
        let configuration: Configuration
        let activeTint: Color?
        let filled: Color?
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(filled != nil ? AnyShapeStyle(.white) : activeTint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.primary))
                .padding(.horizontal, 18)
                .frame(height: 44)
                .background(background, in: .rect(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(activeTint.map { AnyShapeStyle($0.opacity(0.8)) } ?? AnyShapeStyle(Theme.stroke), lineWidth: activeTint == nil ? 1 : 1.5)
                        .opacity(filled == nil ? 1 : 0)
                )
                .contentShape(.rect(cornerRadius: 12))
                .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.45)
        }

        private var background: AnyShapeStyle {
            if let filled { return AnyShapeStyle(filled) }
            if let activeTint { return AnyShapeStyle(activeTint.opacity(0.12)) }
            return AnyShapeStyle(Theme.surface)
        }
    }
}

private struct MeterRow: View {
    let label: String
    let level: Float

    var body: some View {
        HStack(spacing: 8) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            LevelBars(level: level, bars: 16, height: 6).frame(width: 96)
        }
    }
}

private extension View {
    func chipStyle() -> some View {
        padding(.horizontal, 10)
            .frame(height: 28)
            .background(Theme.surface, in: .rect(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.stroke))
    }
}

/// How a speaker looks in transcripts: "Me" in blue, "Them" in orange, and each participant told
/// apart in a colour of their own, the same one everywhere.
enum SpeakerStyle {
    private static let palette: [Color] = [.orange, .pink, .purple, .teal, .indigo, .green, .brown, .cyan, .mint, .red]

    static func color(_ source: AudioSource, participant: Int?) -> Color {
        if let participant { return palette[(participant - 1) % palette.count] }
        return source == .mic ? .blue : .orange
    }

    /// The avatar's text: the participant's number until they're named, else the label's initial.
    static func initial(_ label: String, participant: Int?) -> String {
        if let participant, label == "Participant \(participant)" { return "\(participant)" }
        return String(label.prefix(1)).uppercased()
    }
}

/// A transcript line as a conversation: the speaker's initial, name and time, then the text.
struct SpeakerRow: View {
    @AppStorage(TranscriptFont.key) private var fontSize = TranscriptFont.standard
    let speaker: String
    let source: AudioSource
    var participant: Int?
    let startMs: Int
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Text(SpeakerStyle.initial(speaker, participant: participant))
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(SpeakerStyle.color(source, participant: participant), in: .circle)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(speaker).font(.callout.weight(.semibold))
                    Text(TranscriptExport.timestamp(startMs)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Text(text)
                    .font(.system(size: fontSize + 2))
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// Words being spoken right now, before Whisper's final line replaces them: grey text, a "Live" tag
/// and a cursor, as in the recording design.
private struct LiveTextRow: View {
    @AppStorage(TranscriptFont.key) private var fontSize = TranscriptFont.standard
    let speaker: String
    let source: AudioSource
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "waveform")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(SpeakerStyle.color(source, participant: nil).opacity(0.5), in: .circle)
                .symbolEffect(.variableColor.iterative)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(speaker).font(.callout.weight(.semibold)).foregroundStyle(.secondary)
                    Text("Live").font(.caption.weight(.semibold)).foregroundStyle(.orange)
                }
                (Text(text) + Text(" ▍").foregroundStyle(.orange))
                    .font(.system(size: fontSize + 2))
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(speaker), live: \(text)")
    }
}

/// A screenshot in a transcript: a preview with its time; click to open it.
struct ScreenshotRow: View {
    let shot: MeetingScreenshot
    var caption = "Screenshot"
    /// Lines the preview up with the text of `SpeakerRow`s.
    var leadingInset: CGFloat = 46
    @State private var image: CGImage?

    var body: some View {
        Button {
            NSWorkspace.shared.open(shot.url)
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(.quaternary)
                    if let image {
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    }
                }
                .frame(width: 168, height: 96)
                .clipShape(.rect(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
                VStack(alignment: .leading, spacing: 4) {
                    Text(caption).font(.callout.weight(.semibold))
                    Text(TranscriptExport.timestamp(shot.atMs)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .padding(.leading, leadingInset)
        .help("Open the screenshot")
        .task(id: shot.url) {
            let url = shot.url
            image = await Task.detached { ScreenCapture.thumbnail(of: url, maxPixels: 400) }.value
        }
    }
}

/// A video in a transcript, where it started, as a still with a play button (like `ScreenshotRow`);
/// click to open it once it's finished.
struct VideoRow: View {
    let video: MeetingScreenshot
    var isRecording = false
    /// Having the mic mixed in or being cut down: it opens once that's done.
    var isFinishing = false
    var leadingInset: CGFloat = 46
    @State private var image: CGImage?

    var body: some View {
        Button {
            NSWorkspace.shared.open(video.url)
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(.quaternary)
                    if let image, !isRecording {
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .opacity(isFinishing ? 0.45 : 1)
                    }
                    if isFinishing {
                        ProgressView().controlSize(.regular)
                    } else {
                        Image(systemName: isRecording ? "record.circle" : "play.circle.fill")
                            .font(.system(size: 30))
                            .foregroundStyle(isRecording ? AnyShapeStyle(.red) : AnyShapeStyle(.white.opacity(0.9)))
                            .shadow(radius: 3)
                            .symbolEffect(.pulse, isActive: isRecording)
                    }
                }
                .frame(width: 168, height: 96)
                .clipShape(.rect(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
                VStack(alignment: .leading, spacing: 4) {
                    Text(isRecording ? "Recording video…" : isFinishing ? "Finishing video…" : "Video").font(.callout.weight(.semibold))
                    Text(TranscriptExport.timestamp(video.atMs)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(isRecording || isFinishing)
        .padding(.leading, leadingInset)
        .help(isRecording ? "Recording; it opens once you stop the video"
              : isFinishing ? "Adding your mic or cutting it down; it opens once that's done" : "Open the video")
        // Again once it's finished: the picture may have been cut down.
        .task(id: "\(video.url.path) \(isRecording) \(isFinishing)") {
            guard !isRecording, let thumbnail = await VideoThumbnail.ensure(for: video.url) else { return }
            image = await Task.detached { ScreenCapture.thumbnail(of: thumbnail, maxPixels: 400) }.value
        }
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

/// Asked once, before the first recording: where meeting folders go.
private struct MeetingsFolderSetup: View {
    /// The chosen folder, or nil if cancelled.
    let done: (URL?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Where should meetings be saved?", systemImage: "folder").font(.title2.bold())
            Text("Each meeting gets its own folder, named after its subject and date, with the transcript and summary as Markdown files you can open, share and back up. Screenshots and recordings will go there too.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Image(systemName: "folder.fill").foregroundStyle(.blue)
                Text(MeetingFiles.displayPath(MeetingFiles.suggestedRoot)).monospaced()
            }
            HStack {
                Button("Cancel") { done(nil) }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(MeetingFiles.canUseSuggestedRoot ? "Choose Another Folder…" : "Choose Folder…") {
                    if let url = chooseMeetingsFolder() { done(url) }
                }
                .keyboardShortcut(MeetingFiles.canUseSuggestedRoot ? nil : .defaultAction)
                if MeetingFiles.canUseSuggestedRoot { Button("Use ~/Meetings") {
                    do {
                        try FileManager.default.createDirectory(at: MeetingFiles.suggestedRoot, withIntermediateDirectories: true)
                        done(MeetingFiles.suggestedRoot)
                    } catch {
                        done(nil)
                    }
                }
                .keyboardShortcut(.defaultAction) }
            }
        }
        .padding(24)
        .frame(width: 480)
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

func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}
