import Foundation
import Observation
import WhisperKit

/// A WhisperKit speech model that can be downloaded from Hugging Face.
struct SpeechModel: Identifiable, Hashable, Sendable {
    /// WhisperKit variant, i.e. the folder name in argmaxinc/whisperkit-coreml.
    let id: String
    let name: String
    let detail: String
    let megabytes: Int
    /// Hugging Face repo whose tokenizer this model uses.
    let tokenizerRepo: String

    var englishOnly: Bool { id.hasSuffix(".en") }

    static let catalog = [
        SpeechModel(
            id: "openai_whisper-base.en", name: "Base (English)", detail: "Fastest; fine for clear audio.",
            megabytes: 147, tokenizerRepo: "openai/whisper-base.en"
        ),
        SpeechModel(
            id: "openai_whisper-small.en", name: "Small (English)", detail: "Good balance of speed and accuracy.",
            megabytes: 487, tokenizerRepo: "openai/whisper-small.en"
        ),
        SpeechModel(
            id: "openai_whisper-large-v3-v20240930_turbo_632MB", name: "Large v3 Turbo",
            detail: "Most accurate, any language. Best for accents, crosstalk and jargon.",
            megabytes: 646, tokenizerRepo: "openai/whisper-large-v3"
        ),
    ]
    static let recommended = catalog[2]

    static func find(_ id: String) -> SpeechModel? { catalog.first { $0.id == id } }
}

/// Downloads speech models into the app's data folder, checking free space first.
@MainActor @Observable
final class ModelStore {
    static let shared = ModelStore()

    /// Keep this much free beyond the download itself.
    nonisolated static let spareBytes: Int64 = 2 * 1_000_000_000

    private(set) var downloaded: Set<String> = []
    /// 0...1 for downloads in progress.
    private(set) var progress: [String: Double] = [:]
    private(set) var error: String?
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]

    nonisolated static var dataFolder: URL {
        URL.applicationSupportDirectory.appending(path: "dev.ruy.private-meeting-assistant", directoryHint: .isDirectory)
    }

    /// WhisperKit's download root. Models land in models/argmaxinc/whisperkit-coreml/<variant>
    /// and tokenizers in models/openai/<model>.
    nonisolated static var downloadBase: URL { dataFolder.appending(path: "whisperkit", directoryHint: .isDirectory) }

    nonisolated static func folder(for model: SpeechModel) -> URL {
        downloadBase.appending(path: "models/argmaxinc/whisperkit-coreml/\(model.id)", directoryHint: .isDirectory)
    }

    init() {
        refresh()
    }

    func refresh() {
        downloaded = Set(SpeechModel.catalog.filter { Self.isComplete($0) }.map(\.id))
    }

    /// Where WhisperKit looks for the model's tokenizer first (the Hugging Face cache layout).
    nonisolated static func tokenizerFolder(for model: SpeechModel) -> URL {
        downloadBase.appending(path: "models/\(model.tokenizerRepo)", directoryHint: .isDirectory)
    }

    nonisolated static let tokenizerFiles = ["tokenizer.json", "tokenizer_config.json"]

    nonisolated static func isComplete(_ model: SpeechModel) -> Bool {
        let folder = folder(for: model)
        let tokenizer = tokenizerFolder(for: model)
        return ["AudioEncoder.mlmodelc", "TextDecoder.mlmodelc", "MelSpectrogram.mlmodelc"].allSatisfy {
            FileManager.default.fileExists(atPath: folder.appending(path: $0).path)
        } && tokenizerFiles.allSatisfy {
            FileManager.default.fileExists(atPath: tokenizer.appending(path: $0).path)
        }
    }

    nonisolated static var freeBytes: Int64? {
        let home = URL.homeDirectory
        return try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
    }

    /// Why a download can't start right now, or nil if it can.
    nonisolated static func spaceProblem(for model: SpeechModel) -> String? {
        let needed = Int64(model.megabytes) * 1_000_000 + spareBytes
        guard let free = freeBytes, free < needed else { return nil }
        let format = ByteCountFormatter()
        return "\(model.name) needs \(format.string(fromByteCount: needed)) free (the model plus \(format.string(fromByteCount: spareBytes)) to spare), but only \(format.string(fromByteCount: free)) is available."
    }

    func download(_ model: SpeechModel) {
        guard tasks[model.id] == nil else { return }
        error = nil
        if let problem = Self.spaceProblem(for: model) {
            error = problem
            return
        }
        progress[model.id] = 0
        tasks[model.id] = Task {
            defer {
                tasks[model.id] = nil
                progress[model.id] = nil
                refresh()
            }
            do {
                try FileManager.default.createDirectory(at: Self.downloadBase, withIntermediateDirectories: true)
                let id = model.id
                _ = try await WhisperKit.download(variant: id, downloadBase: Self.downloadBase) { p in
                    let fraction = p.fractionCompleted
                    Task { @MainActor in ModelStore.shared.updateProgress(id, fraction) }
                }
                try await Self.downloadTokenizer(for: model)
            } catch is CancellationError {
            } catch {
                self.error = "Couldn't download \(model.name): \(error.localizedDescription)"
            }
        }
    }

    /// Fetches the tokenizer with the model, so loading never needs the network. (WhisperKit would
    /// otherwise fetch it on first load, and its Hub client can record tokenizer.json as downloaded
    /// without writing the file.)
    private nonisolated static func downloadTokenizer(for model: SpeechModel) async throws {
        let folder = tokenizerFolder(for: model)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for file in tokenizerFiles {
            let url = URL(string: "https://huggingface.co/\(model.tokenizerRepo)/resolve/main/\(file)")!
            let (temp, response) = try await URLSession.shared.download(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw URLError(.badServerResponse, userInfo: [NSURLErrorFailingURLErrorKey: url])
            }
            let destination = folder.appending(path: file)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: temp, to: destination)
        }
    }

    /// Progress callbacks hop to the main actor and can land after the download finished;
    /// ignore those so a finished download doesn't look like it's still running.
    private func updateProgress(_ id: String, _ fraction: Double) {
        if tasks[id] != nil { progress[id] = fraction }
    }

    /// Waits for a download started with `download(_:)` to finish, fail or be cancelled.
    func waitForDownload(_ model: SpeechModel) async {
        await tasks[model.id]?.value
    }

    func cancel(_ model: SpeechModel) {
        tasks[model.id]?.cancel()
    }

    func remove(_ model: SpeechModel) {
        try? FileManager.default.removeItem(at: Self.folder(for: model))
        refresh()
    }
}
