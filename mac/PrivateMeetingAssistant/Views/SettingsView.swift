import AppKit
import AVFoundation
import SwiftUI

enum SettingsKeys {
    static let speechModel = "speechModel"
    static let language = "language"
    static let removeEcho = "removeEcho"
}

/// The Settings window: one tab per area, each setting with a plain-language note on what it does.
struct SettingsView: View {
    static let languages: [(code: String, name: String)] = [
        ("auto", "Detect automatically"), ("en", "English"), ("es", "Spanish"), ("pt", "Portuguese"),
        ("fr", "French"), ("de", "German"), ("it", "Italian"), ("nl", "Dutch"), ("ja", "Japanese"), ("zh", "Chinese"),
    ]

    var body: some View {
        TabView {
            Tab("Transcription", systemImage: "waveform") { TranscriptionSettings() }
            Tab("Summaries", systemImage: "text.alignleft") { Form { SummarySettings() }.formStyle(.grouped) }
            Tab("Storage", systemImage: "folder") { StorageSettings() }
            Tab("Permissions", systemImage: "hand.raised") { PermissionSettings() }
            Tab("About", systemImage: "info.circle") { AboutSettings() }
        }
        .scenePadding(.top)
    }
}

/// Settings › Transcription: the speech model, language and echo removal.
private struct TranscriptionSettings: View {
    @AppStorage(SettingsKeys.speechModel) private var modelID = SpeechModel.recommended.id
    @AppStorage(SettingsKeys.language) private var language = "auto"
    @AppStorage(SettingsKeys.removeEcho) private var removeEcho = true
    private let store = ModelStore.shared

    private var englishOnly: Bool { SpeechModel.find(modelID)?.englishOnly ?? false }

    var body: some View {
        Form {
            Section {
                ForEach(SpeechModel.catalog) { model in
                    ModelRow(model: model, isSelected: modelID == model.id) { modelID = model.id }
                }
                if let error = store.error {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
            } header: {
                Text("Speech model")
            } footer: {
                Text("The speech model turns what's said into text, right on this Mac, using its graphics chip. Bigger models catch more words and names but use more memory and battery. Each is downloaded once from Hugging Face and is ready to use right away; an hour of meeting then adds only about 1 MB of transcript.")
            }

            Section {
                Picker(selection: englishOnly ? .constant("en") : $language) {
                    ForEach(SettingsView.languages, id: \.code) { Text($0.name).tag($0.code) }
                } label: {
                    Text("Language")
                    Text(englishOnly
                        ? "This model only understands English. Pick another model for other languages."
                        : "Choose the language your meetings are in, or let the model work it out. Setting it is a little more accurate.")
                }
                .disabled(englishOnly)

                Toggle(isOn: $removeEcho) {
                    Text("Remove speaker echo")
                    Text("Without headphones your microphone also hears the others through your speakers, so their words would show up twice. This keeps them out of “Me” while everything you say still comes through.")
                }
            } header: {
                Text("While recording")
            }
        }
        .formStyle(.grouped)
        .onAppear { store.refresh() }
    }
}

/// Settings › Storage: where meetings are kept, and setup.
private struct StorageSettings: View {
    @State private var meetingsFolder = MeetingFiles.root
    /// Space taken by the WhisperKit models of earlier versions; nil while counting or once removed.
    @State private var legacyBytes: Int64?
    @State private var legacyError: String?

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    HStack {
                        Button("Change…") {
                            if let url = chooseMeetingsFolder() {
                                MeetingFiles.root = url
                                meetingsFolder = url
                            }
                        }
                        if let meetingsFolder {
                            Button("Show in Finder") { NSWorkspace.shared.open(meetingsFolder) }
                        }
                    }
                } label: {
                    Text("Meetings folder")
                    Text(meetingsFolder?.path.replacingOccurrences(of: NSHomeDirectory(), with: "~") ?? "Not chosen yet")
                        .textSelection(.enabled)
                }
            } header: {
                Text("Your meetings")
            } footer: {
                Text("Every meeting gets its own folder here, named after its subject and date, with the transcript and summary as Markdown files and any screenshots you took. They're ordinary files: open, share or back them up like any document. Changing the folder applies to new meetings; earlier ones stay where they are.")
            }

            if let legacyBytes, legacyBytes > 0 {
                Section {
                    LabeledContent {
                        Button("Move to Trash") {
                            do {
                                try ModelStore.removeLegacyFiles()
                                self.legacyBytes = nil
                            } catch {
                                legacyError = "Couldn't remove them: \(error.localizedDescription)"
                            }
                        }
                    } label: {
                        Text("Old speech models")
                        Text("Earlier versions used a different speech engine. Its models and their optimized copies take \(ByteCountFormatter.string(fromByteCount: legacyBytes, countStyle: .file)) and aren't needed anymore.")
                    }
                    if let legacyError {
                        Label(legacyError, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    }
                }
            }

            Section {
                LabeledContent {
                    Button("Run Setup Again…") { NotificationCenter.default.post(name: SetupView.reopen, object: nil) }
                } label: {
                    Text("First-run setup")
                    Text("Walks through the meetings folder, permissions and downloads again.")
                }
            }
        }
        .formStyle(.grouped)
        .task { legacyBytes = await Task.detached { ModelStore.legacyBytes() }.value }
    }
}

/// Settings › Permissions: what macOS lets the app hear and see, and why it asks.
private struct PermissionSettings: View {
    @State private var micPermission = MicCapture.permission
    @State private var screenPermission = ScreenCapture.hasPermission

    var body: some View {
        Form {
            Section {
                permission(
                    "Microphone", status: micStatus, allowed: micPermission == .authorized,
                    note: "Needed to record you. Recording asks the first time.", pane: "Privacy_Microphone"
                )
                permission(
                    "System audio", status: nil, allowed: nil,
                    note: "Lets the app hear the other people in your calls. If “Them” stays silent while others talk, allow this app under System Audio Recording Only.",
                    pane: "Privacy_ScreenCapture"
                )
                permission(
                    "Screen Recording", status: screenPermission ? "Allowed" : "Not allowed", allowed: screenPermission,
                    note: "Only for screenshots during meetings. Nothing on screen is captured unless you press Screenshot.",
                    pane: "Privacy_ScreenCapture"
                )
            } header: {
                Text("What the app can hear and see")
            } footer: {
                Text("Audio, screenshots and transcripts never leave this Mac. macOS may ask you to reopen the app after you change a permission.")
            }
        }
        .formStyle(.grouped)
        .onAppear {
            micPermission = MicCapture.permission
            screenPermission = ScreenCapture.hasPermission
        }
    }

    private func permission(_ title: String, status: String?, allowed: Bool?, note: String, pane: String) -> some View {
        LabeledContent {
            HStack {
                if let status {
                    Label(status, systemImage: allowed == true ? "checkmark.circle.fill" : "exclamationmark.circle")
                        .foregroundStyle(allowed == true ? .green : .orange)
                }
                Button("Open System Settings") { openPrivacyPane(pane) }
            }
        } label: {
            Text(title)
            Text(note)
        }
    }

    private var micStatus: String {
        switch micPermission {
        case .authorized: "Allowed"
        case .denied: "Not allowed"
        case .restricted: "Blocked by a device policy"
        case .notDetermined: "Not asked yet"
        @unknown default: "Unknown"
        }
    }

    private func openPrivacyPane(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Settings › About: version, the privacy promise, and uninstalling.
private struct AboutSettings: View {
    @AppStorage(Uninstaller.keepMeetingsKey) private var keepMeetings = true
    @State private var confirmUninstall = false
    @State private var uninstallError: String?

    var body: some View {
        Form {
            Section {
                LabeledContent("Version", value: version)
                LabeledContent {
                    Text("Everything stays on this Mac")
                } label: {
                    Text("Privacy")
                    Text("Recording, transcription and summaries all run locally. The only downloads are the models, and nothing you record is ever uploaded.")
                }
            }

            Section {
                Toggle(isOn: $keepMeetings) {
                    Text("Keep my meetings")
                    Text("Leaves your meetings folder in place when the app is removed.")
                }
                LabeledContent {
                    Button("Uninstall…", role: .destructive) { confirmUninstall = true }
                } label: {
                    Text("Uninstall Private Meeting Assistant")
                    Text("Moves the app, its speech models and settings to the Trash\(keepMeetings ? "" : ", along with your meetings folder").")
                }
                if let uninstallError {
                    Label(uninstallError, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
            } header: {
                Text("Uninstall")
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Uninstall Private Meeting Assistant?", isPresented: $confirmUninstall) {
            Button(keepMeetings ? "Uninstall, Keep Meetings" : "Uninstall and Delete Meetings", role: .destructive) {
                do {
                    try Uninstaller.run(keepMeetings: keepMeetings)
                } catch {
                    uninstallError = "Couldn't finish uninstalling: \(error.localizedDescription)"
                }
            }
        } message: {
            Text("These move to the Trash, and the app quits:\n" + Uninstaller.items(keepMeetings: keepMeetings).map { "• \($0.label)" }.joined(separator: "\n"))
        }
    }

    private var version: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }
}

private struct ModelRow: View {
    let model: SpeechModel
    let isSelected: Bool
    let select: () -> Void
    private let store = ModelStore.shared

    var body: some View {
        let downloaded = store.downloaded.contains(model.id)
        HStack(spacing: 12) {
            Button(action: select) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .imageScale(.large)
            }
            .buttonStyle(.plain)
            .help(downloaded ? "Use this model" : "Use this model (download it first)")
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(model.name)
                    if model == .recommended { Text("Recommended").font(.caption).foregroundStyle(.secondary) }
                }
                Text("\(model.detail) \(model.megabytes) MB.").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let progress = store.progress[model.id] {
                ProgressView(value: progress).frame(width: 100)
                Button("Cancel") { store.cancel(model) }
            } else if downloaded {
                Button("Remove") { store.remove(model) }
            } else {
                Button("Download") { store.download(model) }
            }
        }
    }
}

/// Asks where to keep meetings, starting at ~/Meetings. Returns nil if cancelled.
@MainActor
func chooseMeetingsFolder() -> URL? {
    let suggested = MeetingFiles.suggestedRoot
    try? FileManager.default.createDirectory(at: suggested, withIntermediateDirectories: true)
    let panel = NSOpenPanel()
    panel.message = "Choose where to keep your meetings. Each meeting gets its own folder here."
    panel.prompt = "Use This Folder"
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.directoryURL = MeetingFiles.root ?? suggested
    return panel.runModal() == .OK ? panel.url : nil
}

/// Settings › Summaries: which Ollama writes them, which model, and whether to summarize automatically.
private struct SummarySettings: View {
    @AppStorage(MeetingLibrary.summaryEngineKey) private var choice = SummaryEngine.Choice.automatic.rawValue
    @AppStorage(MeetingLibrary.summaryModelKey) private var model = SummaryEngine.recommendedModel.name
    @AppStorage(MeetingLibrary.autoSummarizeKey) private var autoSummarize = true
    private let ollama = SummaryEngine.shared
    private let bytes = ByteCountFormatter()

    /// The engine summaries will actually use with the current choice.
    private var usesYours: Bool {
        switch SummaryEngine.Choice(rawValue: choice) ?? .automatic {
        case .yours: true
        case .downloaded: false
        case .automatic: ollama.yours.problem == nil
        }
    }

    private var models: [String] { usesYours ? ollama.yours.models : ollama.downloadedModels }

    var body: some View {
        Section {
            Picker(selection: $choice) {
                Text("Automatic").tag(SummaryEngine.Choice.automatic.rawValue)
                Text("Your Ollama").tag(SummaryEngine.Choice.yours.rawValue)
                    .selectionDisabled(ollama.yours.problem != nil)
                Text("Downloaded Ollama").tag(SummaryEngine.Choice.downloaded.rawValue)
            } label: {
                Text("Engine")
                Text("Ollama is the free program that runs the summary model. Automatic uses yours if it's running, otherwise a private copy downloaded here.")
            }
            LabeledContent("Your Ollama") {
                if let problem = ollama.yours.problem {
                    Text(problem).foregroundStyle(.secondary)
                } else {
                    Text("\(ollama.yours.version ?? "") · ^[\(ollama.yours.models.count) local model](inflect: true)").foregroundStyle(.secondary)
                }
            }
            LabeledContent("Downloaded Ollama") {
                if let progress = ollama.progress["ollama"] {
                    ProgressView(value: progress).frame(width: 140)
                } else if ollama.isDownloadedInstalled {
                    Text("Installed (\(SummaryEngine.version))").foregroundStyle(.secondary)
                } else {
                    HStack {
                        Text("\(bytes.string(fromByteCount: SummaryEngine.archiveBytes)) download").foregroundStyle(.secondary)
                        Button("Download") { Task { await ollama.installOllama() } }
                            .disabled(SummaryEngine.spaceProblem(modelBytes: SummaryEngine.recommendedModel.bytes) != nil)
                    }
                }
            }
            Picker(selection: $model) {
                ForEach(models, id: \.self) { Text($0).tag($0) }
                if !models.contains(model) {
                    Text("\(model) (not downloaded)").tag(model)
                }
            } label: {
                Text("Model")
                Text("The language model that reads the transcript. Larger ones write better summaries but take longer.")
            }
            if !models.contains(model), usesYours || ollama.isDownloadedInstalled {
                let recommended = SummaryEngine.recommendedModel
                HStack {
                    if let progress = ollama.progress[model] {
                        ProgressView(value: progress).frame(width: 140)
                        Text("Downloading \(model)…").foregroundStyle(.secondary)
                    } else {
                        Text(usesYours ? "Your Ollama doesn't have \(model)." : "\(model) isn't downloaded yet.").foregroundStyle(.secondary)
                        if model == recommended.name {
                            Button("Download (\(bytes.string(fromByteCount: recommended.bytes)))") {
                                Task { await ollama.pull(model, bytes: recommended.bytes, intoYours: usesYours) }
                            }
                        }
                    }
                }
            }
            Toggle(isOn: $autoSummarize) {
                Text("Summarize when a recording stops")
                Text("Writes the summary in the background as soon as you stop. You can always summarize later from the meeting.")
            }
            if let error = ollama.error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
        } header: {
            Text("Summaries")
        } footer: {
            Text("After a meeting, a model on this Mac reads the transcript and writes the main points, decisions and action items. A downloaded Ollama only runs while the app is open. Cloud models are never used.")
        }
        .task { await ollama.refresh() }
    }
}
