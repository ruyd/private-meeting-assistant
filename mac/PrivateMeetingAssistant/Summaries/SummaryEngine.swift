import AppKit
import CryptoKit
import Foundation
import Observation
import OSLog
import Security

private let log = Logger(subsystem: "dev.ruy.private-meeting-assistant", category: "ollama")

/// Which Ollama writes summaries: the one already on this Mac if it's usable, otherwise one this app
/// downloads on request (the official standalone build, verified) and runs privately.
@MainActor @Observable
final class SummaryEngine {
    static let shared = SummaryEngine()

    enum Choice: String, CaseIterable, Identifiable {
        case automatic, yours, downloaded
        var id: Self { self }
    }

    /// Your Ollama, as last checked.
    struct Yours: Equatable {
        var version: String?
        /// Models on this Mac (cloud models, which would send transcripts away, are left out).
        var models: [String] = []
        /// Why it can't be used, or nil if it can.
        var problem: String?
    }

    // The pinned official build: ollama-darwin.tgz from the GitHub release, with its published SHA-256.
    nonisolated static let version = "0.40.5"
    nonisolated static let archiveURL = URL(string: "https://github.com/ollama/ollama/releases/download/v0.40.5/ollama-darwin.tgz")!
    nonisolated static let archiveSHA256 = "75f9907dafa2fd4c61b5967de2ebb81ccc17eb28da9172edbad0dbc717474dcf"
    nonisolated static let archiveBytes: Int64 = 174_000_000
    nonisolated static let installedBytes: Int64 = 540_000_000
    /// Ollama's Developer ID team; the unpacked binary must be signed by it.
    nonisolated static let teamID = "3MU9H2V9Y9"
    /// Structured output (`format` as a JSON schema) and the `think` flag need at least this version.
    nonisolated static let minimumVersion = "0.9.0"

    nonisolated static let yoursURL = URL(string: "http://127.0.0.1:11434")!
    nonisolated static let downloadedURL = URL(string: "http://127.0.0.1:11488")!
    nonisolated static var folder: URL { ModelStore.dataFolder.appending(path: "ollama", directoryHint: .isDirectory) }
    nonisolated static var binary: URL { folder.appending(path: version).appending(path: "ollama") }
    nonisolated static var modelsFolder: URL { folder.appending(path: "models", directoryHint: .isDirectory) }

    /// The model to use when nothing's chosen: the larger one needs 16 GB of memory to run well.
    nonisolated static var recommendedModel: (name: String, bytes: Int64) {
        ProcessInfo.processInfo.physicalMemory >= 16 << 30 ? ("gemma4:12b", 7_700_000_000) : ("gemma3:4b", 3_300_000_000)
    }

    private(set) var yours = Yours()
    /// Models in the downloaded Ollama.
    private(set) var downloadedModels: [String] = []
    /// 0…1 while the downloaded Ollama or a model is downloading, keyed by "ollama" or the model name.
    private(set) var progress: [String: Double] = [:]
    private(set) var error: String?
    @ObservationIgnored private var server: Process?

    var isDownloadedInstalled: Bool { FileManager.default.isExecutableFile(atPath: Self.binary.path) }

    init() {
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { SummaryEngine.shared.stopServer() }
        }
    }

    // MARK: Status

    func refresh() async {
        yours = await Self.check(Self.yoursURL)
        if server != nil, let models = try? await Self.models(at: Self.downloadedURL) {
            downloadedModels = models
        } else if isDownloadedInstalled {
            downloadedModels = Self.modelsOnDisk()
        }
    }

    private nonisolated static func check(_ url: URL) async -> Yours {
        var result = Yours()
        guard let version = try? await Self.version(at: url) else {
            let installed = FileManager.default.fileExists(atPath: "/Applications/Ollama.app") || FileManager.default.fileExists(atPath: "/usr/local/bin/ollama")
            result.problem = installed ? "Ollama is installed but not running." : "Ollama isn't installed."
            return result
        }
        result.version = version
        guard Self.isAtLeast(version, minimumVersion) else {
            result.problem = "Version \(version) is too old (needs \(minimumVersion) or newer)."
            return result
        }
        result.models = (try? await Self.models(at: url)) ?? []
        if result.models.isEmpty { result.problem = "It has no models on this Mac." }
        return result
    }

    nonisolated static func version(at url: URL) async throws -> String {
        var request = URLRequest(url: url.appending(path: "api/version"), timeoutInterval: 2)
        request.httpMethod = "GET"
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let version = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["version"] as? String else {
            throw URLError(.badServerResponse)
        }
        return version
    }

    /// Local models only: cloud models would send transcripts off this Mac.
    nonisolated static func models(at url: URL) async throws -> [String] {
        let (data, _) = try await URLSession.shared.data(for: URLRequest(url: url.appending(path: "api/tags"), timeoutInterval: 3))
        let models = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["models"] as? [[String: Any]] ?? []
        return models.compactMap { m -> String? in
            guard let name = m["name"] as? String, m["remote_host"] == nil, !name.contains("cloud") else { return nil }
            return name
        }.sorted()
    }

    /// Models in the downloaded Ollama's folder, read from its manifests, when its server isn't running.
    private nonisolated static func modelsOnDisk() -> [String] {
        let manifests = modelsFolder.appending(path: "manifests/registry.ollama.ai/library")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: manifests.path)) ?? []
        return names.flatMap { name in
            ((try? FileManager.default.contentsOfDirectory(atPath: manifests.appending(path: name).path)) ?? []).map { "\(name):\($0)" }
        }.sorted()
    }

    nonisolated static func isAtLeast(_ version: String, _ minimum: String) -> Bool {
        let a = version.split(separator: ".").compactMap { Int($0) }
        let b = minimum.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return true
    }

    // MARK: Choosing

    enum Unavailable: LocalizedError {
        case notSetUp(String)
        var errorDescription: String? {
            switch self { case .notSetUp(let why): why }
        }
    }

    /// The server to summarize with, started if needed, with `model` available on it.
    func endpoint(choice: Choice, model: String) async throws -> URL {
        await refresh()
        let yoursUsable = yours.problem == nil && yours.models.contains(model)
        switch choice {
        case .yours:
            guard yours.problem == nil else { throw Unavailable.notSetUp("Your Ollama can't be used: \(yours.problem!)") }
            guard yours.models.contains(model) else { throw Unavailable.notSetUp("Your Ollama doesn't have \(model). Choose another model in Settings.") }
            return Self.yoursURL
        case .automatic where yoursUsable:
            return Self.yoursURL
        case .automatic, .downloaded:
            guard isDownloadedInstalled else {
                throw Unavailable.notSetUp("Set up summaries in Settings: download Ollama, or start your own.")
            }
            try await startServer()
            guard (try? await Self.models(at: Self.downloadedURL))?.contains(model) == true else {
                throw Unavailable.notSetUp("Download \(model) in Settings › Summaries first.")
            }
            return Self.downloadedURL
        }
    }

    // MARK: Downloaded Ollama

    /// Why the downloaded Ollama (plus `modelBytes` of model) can't be installed now, or nil.
    nonisolated static func spaceProblem(modelBytes: Int64) -> String? {
        let needed = archiveBytes + installedBytes + modelBytes + ModelStore.spareBytes
        guard let free = ModelStore.freeBytes, free < needed else { return nil }
        let f = ByteCountFormatter()
        return "Summaries need \(f.string(fromByteCount: needed)) free, but only \(f.string(fromByteCount: free)) is available."
    }

    /// Downloads, verifies and unpacks the pinned Ollama build into the app's data folder.
    func installOllama() async {
        guard !isDownloadedInstalled, progress["ollama"] == nil else { return }
        error = nil
        if let problem = Self.spaceProblem(modelBytes: Self.recommendedModel.bytes) {
            error = problem
            return
        }
        progress["ollama"] = 0
        defer { progress["ollama"] = nil }
        let staging = Self.folder.appending(path: "download-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: staging) }
            let archive = try await FileDownload.fetch(Self.archiveURL, to: staging.appending(path: "ollama-darwin.tgz")) { fraction in
                Task { @MainActor in SummaryEngine.shared.progress["ollama"] = fraction * 0.9 }
            }
            guard try Self.sha256(of: archive) == Self.archiveSHA256 else {
                throw Unavailable.notSetUp("The Ollama download didn't match its published checksum, so it wasn't installed.")
            }
            let unpacked = staging.appending(path: "unpacked")
            try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: true)
            try Self.run("/usr/bin/tar", ["-xzf", archive.path, "-C", unpacked.path])
            guard Self.isSignedByOllama(unpacked.appending(path: "ollama")) else {
                throw Unavailable.notSetUp("The Ollama download isn't signed by Ollama, so it wasn't installed.")
            }
            let target = Self.binary.deletingLastPathComponent()
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: unpacked, to: target)
            log.notice("installed Ollama \(Self.version, privacy: .public)")
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Downloads `model` into the downloaded Ollama, or into yours (`intoYours`), with progress.
    func pull(_ model: String, bytes: Int64, intoYours: Bool) async {
        guard progress[model] == nil else { return }
        error = nil
        if let free = ModelStore.freeBytes, free < bytes + ModelStore.spareBytes {
            error = "\(model) needs \(ByteCountFormatter().string(fromByteCount: bytes + ModelStore.spareBytes)) free (with room to spare)."
            return
        }
        progress[model] = 0
        defer { progress[model] = nil }
        do {
            let url = intoYours ? Self.yoursURL : Self.downloadedURL
            if !intoYours { try await startServer() }
            var request = URLRequest(url: url.appending(path: "api/pull"), timeoutInterval: 3_600)
            request.httpMethod = "POST"
            request.httpBody = try JSONSerialization.data(withJSONObject: ["model": model, "stream": true])
            let (lines, _) = try await URLSession.shared.bytes(for: request)
            for try await line in lines.lines {
                guard let event = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
                if let message = event["error"] as? String { throw Unavailable.notSetUp("Couldn't download \(model): \(message)") }
                if let total = event["total"] as? Double, let done = event["completed"] as? Double, total > 0 {
                    progress[model] = done / total
                }
            }
            await refresh()
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Starts the downloaded Ollama on its private port, with its models in the app's folder.
    func startServer() async throws {
        if server?.isRunning == true { return }
        guard isDownloadedInstalled else { throw Unavailable.notSetUp("Ollama isn't downloaded yet.") }
        try FileManager.default.createDirectory(at: Self.modelsFolder, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = Self.binary
        process.arguments = ["serve"]
        var env = ProcessInfo.processInfo.environment
        env["OLLAMA_HOST"] = "\(Self.downloadedURL.host!):\(Self.downloadedURL.port!)"
        env["OLLAMA_MODELS"] = Self.modelsFolder.path
        process.environment = env
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        server = process
        for _ in 0..<50 {
            if (try? await Self.version(at: Self.downloadedURL)) != nil { return }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw Unavailable.notSetUp("The downloaded Ollama didn't start.")
    }

    func stopServer() {
        server?.terminate()
        server = nil
    }

    // MARK: Verification

    nonisolated static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// True if `binary` has a valid Developer ID signature from Ollama's team.
    nonisolated static func isSignedByOllama(_ binary: URL) -> Bool {
        var code: SecStaticCode?
        var requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(binary as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(
                  "anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\"" as CFString, [], &requirement
              ) == errSecSuccess
        else { return false }
        return SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), requirement) == errSecSuccess
    }

    private nonisolated static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw Unavailable.notSetUp("\(tool) failed (\(process.terminationStatus)).") }
    }
}

/// A file download with progress, saved to a given location.
private final class FileDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let onProgress: @Sendable (Double) -> Void
    private var continuation: CheckedContinuation<URL, any Error>?

    private init(destination: URL, onProgress: @escaping @Sendable (Double) -> Void) {
        self.destination = destination
        self.onProgress = onProgress
    }

    nonisolated static func fetch(_ url: URL, to destination: URL, onProgress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let download = FileDownload(destination: destination, onProgress: onProgress)
        let session = URLSession(configuration: .default, delegate: download, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withCheckedThrowingContinuation { continuation in
            download.continuation = continuation
            session.downloadTask(with: url).resume()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesExpectedToWrite > 0 { onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            continuation?.resume(returning: destination)
        } catch {
            continuation?.resume(throwing: error)
        }
        continuation = nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let error {
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }
}
