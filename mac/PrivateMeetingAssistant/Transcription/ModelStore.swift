import Foundation
import Observation

/// A Whisper model in whisper.cpp's format: one file, downloaded from Hugging Face.
struct SpeechModel: Identifiable, Hashable, Sendable {
    /// The file's name without "ggml-" and ".bin", as in huggingface.co/ggerganov/whisper.cpp.
    let id: String
    let name: String
    let detail: String
    let megabytes: Int

    var englishOnly: Bool { id.hasSuffix(".en") }

    static let catalog = [
        SpeechModel(id: "base.en", name: "Base (English)", detail: "Fastest; fine for clear audio.", megabytes: 148),
        SpeechModel(id: "small.en", name: "Small (English)", detail: "Good balance of speed and accuracy.", megabytes: 488),
        SpeechModel(
            id: "large-v3-turbo-q5_0", name: "Large v3 Turbo",
            detail: "Most accurate, any language. Best for accents, crosstalk and jargon.", megabytes: 574
        ),
    ]
    static let recommended = catalog[2]

    static func find(_ id: String) -> SpeechModel? { catalog.first { $0.id == id } }

    /// The WhisperKit models earlier versions used, and the whisper.cpp model that replaces each.
    static let replacements = [
        "openai_whisper-base.en": "base.en",
        "openai_whisper-small.en": "small.en",
        "openai_whisper-large-v3-v20240930_turbo_632MB": "large-v3-turbo-q5_0",
    ]
}

/// Downloads speech models into the app's data folder, checking free space first.
@MainActor @Observable
final class ModelStore {
    static let shared = ModelStore()

    /// Keep this much free beyond the download itself.
    nonisolated static let spareBytes: Int64 = 2 * 1_000_000_000
    nonisolated static let baseURL = URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main")!

    private(set) var downloaded: Set<String> = []
    /// 0...1 for downloads in progress.
    private(set) var progress: [String: Double] = [:]
    private(set) var error: String?
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]

    nonisolated static var dataFolder: URL {
        URL.applicationSupportDirectory.appending(path: "dev.ruy.private-meeting-assistant", directoryHint: .isDirectory)
    }

    /// Where models are kept (the same folder the earlier Tauri version used, so its downloads count).
    nonisolated static var modelsFolder: URL { dataFolder.appending(path: "models", directoryHint: .isDirectory) }

    nonisolated static func file(for model: SpeechModel) -> URL {
        modelsFolder.appending(path: "ggml-\(model.id).bin")
    }

    init() {
        // Earlier versions saved a WhisperKit model's name as the choice; keep the same choice.
        let defaults = UserDefaults.standard
        if let old = defaults.string(forKey: SettingsKeys.speechModel), let new = SpeechModel.replacements[old] {
            defaults.set(new, forKey: SettingsKeys.speechModel)
        }
        refresh()
    }

    func refresh() {
        downloaded = Set(SpeechModel.catalog.filter { Self.isComplete($0) }.map(\.id))
    }

    /// Downloads land under another name and are renamed when complete, so a file here is whole.
    nonisolated static func isComplete(_ model: SpeechModel) -> Bool {
        FileManager.default.fileExists(atPath: file(for: model).path)
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
                let id = model.id
                try await Self.fetch(model) { fraction in
                    Task { @MainActor in ModelStore.shared.updateProgress(id, fraction) }
                }
            } catch is CancellationError {
            } catch let error as URLError where error.code == .cancelled {
            } catch {
                self.error = "Couldn't download \(model.name): \(error.localizedDescription)"
            }
        }
    }

    /// Downloads the model's file to a temporary place, then moves it into the models folder.
    private nonisolated static func fetch(_ model: SpeechModel, progress: @escaping @Sendable (Double) -> Void) async throws {
        let url = baseURL.appending(path: "ggml-\(model.id).bin")
        let (temp, response) = try await URLSession.shared.download(from: url, delegate: DownloadProgress(progress))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            try? FileManager.default.removeItem(at: temp)
            throw URLError(.badServerResponse, userInfo: [NSURLErrorFailingURLErrorKey: url])
        }
        try FileManager.default.createDirectory(at: modelsFolder, withIntermediateDirectories: true)
        let destination = file(for: model)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temp, to: destination)
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
        try? FileManager.default.removeItem(at: Self.file(for: model))
        refresh()
    }

    // MARK: Files from earlier versions

    /// WhisperKit's models, and Core ML's compiled copies of them, left by earlier versions.
    nonisolated static var legacyFolders: [URL] {
        [
            dataFolder.appending(path: "whisperkit", directoryHint: .isDirectory),
            URL.cachesDirectory.appending(path: "dev.ruy.private-meeting-assistant/com.apple.e5rt.e5bundlecache", directoryHint: .isDirectory),
        ].filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// How much space the files from earlier versions take.
    nonisolated static func legacyBytes() -> Int64 {
        legacyFolders.reduce(0) { total, folder in
            let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.totalFileAllocatedSizeKey])
            var size: Int64 = 0
            while let url = files?.nextObject() as? URL {
                size += Int64((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
            }
            return total + size
        }
    }

    /// Moves the files from earlier versions to the Trash.
    nonisolated static func removeLegacyFiles() throws {
        for folder in legacyFolders {
            try FileManager.default.trashItem(at: folder, resultingItemURL: nil)
        }
    }
}

/// Reports a download's progress from its task.
private final class DownloadProgress: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let report: @Sendable (Double) -> Void
    private var observation: NSKeyValueObservation?

    init(_ report: @escaping @Sendable (Double) -> Void) {
        self.report = report
    }

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        observation = task.progress.observe(\.fractionCompleted) { [report] progress, _ in
            report(progress.fractionCompleted)
        }
    }
}
