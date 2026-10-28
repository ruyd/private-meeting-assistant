import AVFoundation
import SwiftUI

/// First-run setup: where meetings go, the two permissions, and the downloads, so nothing surprises
/// you mid-meeting. Shown once at first launch; Settings can open it again.
struct SetupView: View {
    static let completedKey = "setupCompleted"
    /// Posted by Settings to walk through setup again.
    static let reopen = Notification.Name("reopenSetup")

    let done: () -> Void
    @State private var step = Step.welcome

    enum Step: Int, CaseIterable {
        case welcome, folder, microphone, systemAudio, downloads
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case .welcome: WelcomeStep()
                case .folder: FolderStep()
                case .microphone: MicrophoneStep()
                case .systemAudio: SystemAudioStep()
                case .downloads: DownloadsStep()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(28)

            Divider()
            HStack {
                HStack(spacing: 6) {
                    ForEach(Step.allCases, id: \.self) { s in
                        Circle().fill(s == step ? Color.accentColor : Color.secondary.opacity(0.3)).frame(width: 7, height: 7)
                    }
                }
                Spacer()
                if step != .welcome {
                    Button("Back") { step = Step(rawValue: step.rawValue - 1)! }
                }
                if step == .downloads {
                    Button("Done") { done() }.keyboardShortcut(.defaultAction)
                } else {
                    Button(step == .welcome ? "Get Started" : "Continue") {
                        if step == .folder, MeetingFiles.root == nil, !useSuggestedFolder() { return }
                        step = Step(rawValue: step.rawValue + 1)!
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding()
        }
        .frame(width: 560, height: 460)
    }

    /// Uses ~/Meetings, or in the App Store build (which can only use folders chosen in an open
    /// panel) asks for one. False if none was chosen.
    private func useSuggestedFolder() -> Bool {
        guard MeetingFiles.canUseSuggestedRoot else {
            guard let url = chooseMeetingsFolder() else { return false }
            MeetingFiles.root = url
            return true
        }
        try? FileManager.default.createDirectory(at: MeetingFiles.suggestedRoot, withIntermediateDirectories: true)
        MeetingFiles.root = MeetingFiles.suggestedRoot
        return true
    }
}

private struct StepHeader: View {
    let symbol: String
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: symbol).font(.system(size: 34)).foregroundStyle(.tint)
            Text(title).font(.title.bold())
            Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 12)
    }
}

private struct WelcomeStep: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            StepHeader(
                symbol: "waveform.and.mic",
                title: "Welcome to Private Meeting Assistant",
                text: "It transcribes your meetings as they happen, with you as “Me” and each other voice as its own participant (Participant 1, 2, 3…, named when you stop), then writes a summary with decisions and action items."
            )
            Label("Works with Zoom, Meet, Teams or any call app. No bot joins the meeting.", systemImage: "person.2")
            Label("Everything runs on this Mac. Audio and transcripts never leave it.", systemImage: "lock")
            Label("Meetings are saved as Markdown files you own.", systemImage: "doc.text")
        }
    }
}

private struct FolderStep: View {
    @State private var folder = MeetingFiles.root

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            StepHeader(
                symbol: "folder",
                title: "Where should meetings be saved?",
                text: "Each meeting gets a folder named after its subject and date, with the transcript and summary as Markdown files. Screenshots and recordings will go there too."
            )
            HStack {
                Image(systemName: "folder.fill").foregroundStyle(.blue)
                Text(MeetingFiles.displayPath(folder ?? MeetingFiles.suggestedRoot)).monospaced()
                Spacer()
                Button("Choose…") {
                    if let url = chooseMeetingsFolder() {
                        MeetingFiles.root = url
                        folder = url
                    }
                }
            }
            if folder == nil {
                Text(MeetingFiles.canUseSuggestedRoot
                    ? "Continue to use ~/Meetings."
                    : "Continue to choose a folder; you can create a new one, such as ~/Meetings.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

private struct MicrophoneStep: View {
    @State private var status = MicCapture.permission

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            StepHeader(
                symbol: "mic",
                title: "Your microphone",
                text: "What you say is transcribed as “Me”. macOS asks once whether this app may use the microphone."
            )
            HStack {
                switch status {
                case .authorized:
                    Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                case .denied, .restricted:
                    Label("Not allowed", systemImage: "xmark.circle.fill").foregroundStyle(.red)
                    Button("Open System Settings") { openPrivacyPane("Privacy_Microphone") }
                default:
                    Button("Allow Microphone") {
                        Task {
                            _ = await MicCapture.requestPermission()
                            status = MicCapture.permission
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
    }
}

private struct SystemAudioStep: View {
    enum TestResult { case untested, testing, heard, silent }
    @State private var result = TestResult.untested

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            StepHeader(
                symbol: "speaker.wave.2",
                title: "The other participants",
                text: "Their voices come from your call app, which this app records directly, telling each voice apart as Participant 1, 2, 3…. macOS asks to allow System Audio Recording. The test plays a short sound and checks it's heard."
            )
            HStack {
                Button(result == .testing ? "Testing…" : "Test System Audio") { Task { await test() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(result == .testing)
                switch result {
                case .heard:
                    Label("Working", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                case .silent:
                    Label("Nothing was heard", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Button("Open System Settings") { openPrivacyPane("Privacy_ScreenCapture") }
                default:
                    EmptyView()
                }
            }
            if result == .silent {
                Text("Allow this app under **System Audio Recording Only**, check the volume isn't muted, then test again.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    /// Captures system audio for a moment while a system sound plays (from another process, since the
    /// capture leaves this app's own sound out).
    private func test() async {
        result = .testing
        let peak = PeakMeter()
        let capture = SystemAudioCapture(target: .allExceptThisApp) { peak.record($0) }
        do {
            try capture.start()
            try? await Task.sleep(for: .milliseconds(300))
            let sound = Process()
            sound.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
            sound.arguments = ["/System/Library/Sounds/Glass.aiff"]
            try sound.run()
            try? await Task.sleep(for: .seconds(1.5))
            capture.stop()
            result = peak.value > 0.001 ? .heard : .silent
        } catch {
            capture.stop()
            result = .silent
        }
    }
}

/// The loudest sample seen, shared with an audio thread.
private final class PeakMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var peak: Float = 0
    var value: Float { lock.withLock { peak } }
    func record(_ chunk: AudioChunk) {
        let m = chunk.samples.map(abs).max() ?? 0
        lock.withLock { peak = max(peak, m) }
    }
}

func openPrivacyPane(_ anchor: String) {
    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
        NSWorkspace.shared.open(url)
    }
}

/// Everything still missing, with one total and one free-space check.
private struct DownloadsStep: View {
    @AppStorage(SettingsKeys.speechModel) private var speechModelID = SpeechModel.recommended.id
    @AppStorage(MeetingLibrary.summaryModelKey) private var summaryModel = SummaryEngine.recommendedModel.name
    @State private var running = false
    private let models = ModelStore.shared
    private let ollama = SummaryEngine.shared
    private let bytes = ByteCountFormatter()

    private struct Item: Identifiable {
        let id: String
        let name: String
        let size: Int64
        let ready: Bool
        let progress: Double?
    }

    private var speechModel: SpeechModel { SpeechModel.find(speechModelID) ?? .recommended }
    /// Your Ollama can write summaries without downloading Ollama itself.
    private var yoursUsable: Bool { ollama.yours.problem == nil }
    /// Without your Ollama, the App Store version summarizes with Apple's model: nothing to download.
    private var usesApple: Bool { !yoursUsable && !SummaryEngine.offersDownload }

    private var items: [Item] {
        var items = [Item(
            id: "speech", name: "Speech model: \(speechModel.name)", size: Int64(speechModel.megabytes) * 1_000_000,
            ready: models.downloaded.contains(speechModel.id), progress: models.progress[speechModel.id]
        )]
        if usesApple {
            items.append(Item(
                id: "apple", name: "Summaries: Apple Intelligence, built into macOS", size: 0,
                ready: SummaryEngine.appleProblem == nil, progress: nil
            ))
            return items
        }
        if !yoursUsable {
            items.append(Item(
                id: "ollama", name: "Ollama \(SummaryEngine.version), for summaries", size: SummaryEngine.archiveBytes + SummaryEngine.installedBytes,
                ready: ollama.isDownloadedInstalled, progress: ollama.progress["ollama"]
            ))
        }
        let modelsThere = yoursUsable ? ollama.yours.models : ollama.downloadedModels
        items.append(Item(
            id: "summary", name: "Summary model: \(summaryModel)\(yoursUsable ? " (in your Ollama)" : "")",
            size: SummaryEngine.recommendedModel.bytes, ready: modelsThere.contains(summaryModel), progress: ollama.progress[summaryModel]
        ))
        return items
    }

    private var missing: Int64 { items.filter { !$0.ready }.map(\.size).reduce(0, +) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            StepHeader(
                symbol: "arrow.down.circle",
                title: "Download what's needed",
                text: "Transcription and summaries run on this Mac, so they need their models once. You can also do this later in Settings."
            )
            ForEach(items) { item in
                HStack {
                    Image(systemName: item.ready ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(item.ready ? .green : .secondary)
                    Text(item.name)
                    Spacer()
                    if let progress = item.progress {
                        ProgressView(value: progress).frame(width: 120)
                    } else if item.id == "apple" {
                        Text(SummaryEngine.appleProblem ?? "Ready").foregroundStyle(.secondary)
                    } else {
                        Text(item.ready ? "Ready" : bytes.string(fromByteCount: item.size)).foregroundStyle(.secondary)
                    }
                }
            }
            if missing > 0 {
                let needed = missing + ModelStore.spareBytes
                let free = ModelStore.freeBytes ?? .max
                HStack {
                    Text("\(bytes.string(fromByteCount: missing)) to download · \(free == .max ? "" : bytes.string(fromByteCount: free) + " free")")
                        .foregroundStyle(free < needed ? .red : .secondary)
                    Spacer()
                    Button(running ? "Downloading…" : "Download All") { Task { await downloadAll() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(running || free < needed)
                }
                if free < needed {
                    Text("Free up \(bytes.string(fromByteCount: needed - free)) first: the downloads plus \(bytes.string(fromByteCount: ModelStore.spareBytes)) to spare.")
                        .font(.callout).foregroundStyle(.red)
                }
                Text("Each hour of meeting then adds about 1 MB of transcript.").font(.callout).foregroundStyle(.secondary)
            } else {
                Label("Everything's ready.", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
            }
            if let error = models.error ?? ollama.error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
        }
        .task { await ollama.refresh() }
    }

    private func downloadAll() async {
        running = true
        defer { running = false }
        if !models.downloaded.contains(speechModel.id) {
            models.download(speechModel)
            await models.waitForDownload(speechModel)
        }
        if usesApple { return }
        if !yoursUsable, !ollama.isDownloadedInstalled {
            await ollama.installOllama()
            guard ollama.isDownloadedInstalled else { return }
        }
        await ollama.refresh()
        let modelsThere = yoursUsable ? ollama.yours.models : ollama.downloadedModels
        if !modelsThere.contains(summaryModel) {
            await ollama.pull(summaryModel, bytes: SummaryEngine.recommendedModel.bytes, intoYours: yoursUsable)
        }
    }
}
