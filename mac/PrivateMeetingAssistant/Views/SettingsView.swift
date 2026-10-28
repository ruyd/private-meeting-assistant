import AppKit
import AVFoundation
import SwiftUI

enum SettingsKeys {
    static let speechModel = "speechModel"
    static let language = "language"
    static let removeEcho = "removeEcho"
}

struct SettingsView: View {
    @AppStorage(SettingsKeys.speechModel) private var modelID = SpeechModel.recommended.id
    @AppStorage(SettingsKeys.language) private var language = "auto"
    @AppStorage(SettingsKeys.removeEcho) private var removeEcho = true
    @AppStorage(Uninstaller.keepMeetingsKey) private var keepMeetings = true
    @State private var meetingsFolder = MeetingFiles.root
    @State private var confirmUninstall = false
    @State private var uninstallError: String?
    @State private var micPermission = MicCapture.permission
    private let store = ModelStore.shared

    private static let languages: [(code: String, name: String)] = [
        ("auto", "Detect automatically"), ("en", "English"), ("es", "Spanish"), ("pt", "Portuguese"),
        ("fr", "French"), ("de", "German"), ("it", "Italian"), ("nl", "Dutch"), ("ja", "Japanese"), ("zh", "Chinese"),
    ]

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
                Text("Models are downloaded once from Hugging Face and run on this Mac. Each hour of meeting adds about 1 MB of transcript.")
            }

            Section {
                Picker("Language", selection: englishOnly ? .constant("en") : $language) {
                    ForEach(Self.languages, id: \.code) { Text($0.name).tag($0.code) }
                }
                .disabled(englishOnly)
            } footer: {
                if englishOnly { Text("English-only models always transcribe English.") }
            }

            SummarySettings()

            Section {
                Toggle("Remove speaker echo from my microphone", isOn: $removeEcho)
            } header: {
                Text("Recording")
            } footer: {
                Text("Without headphones, your mic also hears the other participants through the speakers. This keeps their voices out of “Me”, while everything you say still comes through. It learns your setup during the first second the others speak.")
            }

            Section("Permissions") {
                LabeledContent("Microphone") {
                    HStack {
                        Text(micPermissionText).foregroundStyle(.secondary)
                        Button("Open Settings") { openPrivacyPane("Privacy_Microphone") }
                    }
                }
                LabeledContent("System audio") {
                    Button("Open Settings") { openPrivacyPane("Privacy_ScreenCapture") }
                }
                Text("macOS asks the first time you record. If “Them” stays silent while audio is playing, allow this app under **System Audio Recording Only**.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Meetings folder") {
                    HStack {
                        Text(meetingsFolder?.path.replacingOccurrences(of: NSHomeDirectory(), with: "~") ?? "Not chosen yet")
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
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
                }
                Toggle("Keep my meetings when uninstalling", isOn: $keepMeetings)
                HStack {
                    Spacer()
                    Button("Uninstall Private Meeting Assistant…", role: .destructive) { confirmUninstall = true }
                }
                if let uninstallError {
                    Label(uninstallError, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
            } header: {
                Text("Data")
            } footer: {
                Text("Each meeting is a folder here, with transcript.md and summary.md. Changing the folder applies to new meetings; existing ones stay where they are. Uninstall moves the app, its speech models and settings to the Trash, and your meetings folder too if you uncheck the box.")
            }

            Section {
                Button("Run Setup Again…") { NotificationCenter.default.post(name: SetupView.reopen, object: nil) }
            } footer: {
                Text("Walks through the meetings folder, permissions and downloads again.")
            }

            Section("About") {
                LabeledContent("Version", value: version)
                LabeledContent("Privacy", value: "Audio and transcripts stay on this Mac.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
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
        .onAppear {
            store.refresh()
            micPermission = MicCapture.permission
        }
    }

    private var micPermissionText: String {
        switch micPermission {
        case .authorized: "Allowed"
        case .denied: "Denied"
        case .restricted: "Blocked by a device policy"
        case .notDetermined: "Not asked yet"
        @unknown default: "Unknown"
        }
    }

    private var version: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }

    private func openPrivacyPane(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
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
            Picker("Engine", selection: $choice) {
                Text("Automatic").tag(SummaryEngine.Choice.automatic.rawValue)
                Text("Your Ollama").tag(SummaryEngine.Choice.yours.rawValue)
                    .selectionDisabled(ollama.yours.problem != nil)
                Text("Downloaded Ollama").tag(SummaryEngine.Choice.downloaded.rawValue)
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
            Picker("Model", selection: $model) {
                ForEach(models, id: \.self) { Text($0).tag($0) }
                if !models.contains(model) {
                    Text("\(model) (not downloaded)").tag(model)
                }
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
            Toggle("Summarize automatically when a recording stops", isOn: $autoSummarize)
            if let error = ollama.error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
        } header: {
            Text("Summaries")
        } footer: {
            Text("Summaries are written on this Mac by a local model in Ollama. Automatic uses your Ollama when it's running, otherwise one downloaded here (it runs privately and stops when the app quits). Cloud models are never used.")
        }
        .task { await ollama.refresh() }
    }
}
