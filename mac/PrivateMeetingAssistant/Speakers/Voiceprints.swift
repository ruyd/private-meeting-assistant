import CoreML
import CryptoKit
import Foundation
import Observation
import OSLog

private let log = Logger(subsystem: "dev.ruy.private-meeting-assistant", category: "speakers")

/// The speaker-embedding model that tells voices apart: WeSpeaker's ResNet34 (trained on VoxCeleb),
/// as converted to Core ML by Fluid Inference, 8 MB. It turns up to 10 s of speech into a 256-number
/// voiceprint; voiceprints of the same person point the same way (cosine similarity).
///
/// Pinned to one commit of huggingface.co/FluidInference/speaker-diarization-coreml, each file checked
/// against its SHA-256. CC-BY-4.0: WeSpeaker, pyannote and Fluid Inference (modified Core ML conversion).
enum VoiceprintModel {
    static let revision = "7eab74f3463c736418d0eb10296261ae581146c9"
    static let base = URL(string: "https://huggingface.co/FluidInference/speaker-diarization-coreml/resolve/\(revision)/wespeaker_v2.mlmodelc")!
    static let files: [(path: String, sha256: String)] = [
        ("analytics/coremldata.bin", "d2b1fcde6121aea3ff0e14c1dc50d09dacb0314a2e89156353c31804230a422f"),
        ("coremldata.bin", "6feb2472a71fa9d8a84020c85206138a4f6261c565c9884bf518d59dd5838da7"),
        ("metadata.json", "ddc4858b4051254098015cd0b97080149839d697faf7b036f933190e70b26758"),
        ("model.mil", "2850f775d6ba659f01f616fed77ce6a45a25de3eb7e4bf3a4b07b658be4e13dd"),
        ("weights/weight.bin", "34004f6798d35cad7071e2fdc67e63faaa782f53697e1cb49bcb452cf81ae151"),
    ]
    static let megabytes = 8

    static var folder: URL { ModelStore.modelsFolder.appending(path: "wespeaker_v2.mlmodelc", directoryHint: .isDirectory) }

    /// Downloads go to a temporary folder that's moved here when complete, so a folder here is whole.
    static var isDownloaded: Bool { FileManager.default.fileExists(atPath: folder.path) }

    enum Failure: LocalizedError {
        case checksum(String)
        var errorDescription: String? {
            switch self {
            case .checksum(let file): "The downloaded speaker model's \(file) didn't match its checksum."
            }
        }
    }

    static func download() async throws {
        let temp = FileManager.default.temporaryDirectory.appending(path: "wespeaker-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: temp) }
        for file in files {
            let (downloaded, response) = try await URLSession.shared.download(from: base.appending(path: file.path))
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            let data = try Data(contentsOf: downloaded)
            guard SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == file.sha256 else {
                throw Failure.checksum(file.path)
            }
            let target = temp.appending(path: file.path)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: target)
        }
        try FileManager.default.createDirectory(at: ModelStore.modelsFolder, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.moveItem(at: temp, to: folder)
    }
}

/// Downloads the speaker model when telling speakers apart is turned on, for Settings and the
/// Record page to show.
@MainActor @Observable
final class VoiceprintStore {
    static let shared = VoiceprintStore()

    private(set) var isDownloaded = VoiceprintModel.isDownloaded
    private(set) var isDownloading = false
    private(set) var error: String?

    func downloadIfNeeded() async {
        guard !isDownloaded, !isDownloading else { return }
        isDownloading = true
        error = nil
        defer { isDownloading = false }
        do {
            try await VoiceprintModel.download()
            isDownloaded = true
        } catch {
            log.error("speaker model download failed: \(error.localizedDescription, privacy: .public)")
            self.error = "Couldn't download the speaker model: \(error.localizedDescription)"
        }
    }
}

/// Computes voiceprints with the loaded model. Used by one transcription worker at a time.
final class Voiceprinter: @unchecked Sendable {
    /// The model's fixed input: 10 s at 16 kHz, and a mask of its 589 frames.
    static let windowSamples = 160_000
    static let maskFrames = 589
    static let dimensions = 256

    private let model: MLModel
    private let waveform: MLMultiArray
    private let mask: MLMultiArray

    init(model: MLModel) throws {
        self.model = model
        // The model takes three clips at a time; only the first is used, the others stay silent.
        waveform = try MLMultiArray(shape: [3, Self.windowSamples as NSNumber], dataType: .float32)
        mask = try MLMultiArray(shape: [3, Self.maskFrames as NSNumber], dataType: .float32)
        let w = waveform.dataPointer.assumingMemoryBound(to: Float.self)
        w.update(repeating: 0, count: 3 * Self.windowSamples)
        let m = mask.dataPointer.assumingMemoryBound(to: Float.self)
        m.update(repeating: 0, count: 3 * Self.maskFrames)
        m.update(repeating: 1, count: Self.maskFrames)
    }

    /// Loads the downloaded model, or nil if it isn't there or won't load.
    static func load() -> Voiceprinter? {
        guard VoiceprintModel.isDownloaded else { return nil }
        do {
            return try Voiceprinter(model: MLModel(contentsOf: VoiceprintModel.folder, configuration: MLModelConfiguration()))
        } catch {
            log.error("couldn't load the speaker model: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// A unit-length voiceprint of 16 kHz speech. Shorter clips are repeated to fill the model's 10 s
    /// window (as pyannote does); longer ones use their middle 10 s.
    func embed(_ samples: ArraySlice<Float>) -> [Float]? {
        guard !samples.isEmpty else { return nil }
        let clip = samples.count > Self.windowSamples
            ? samples.dropFirst((samples.count - Self.windowSamples) / 2).prefix(Self.windowSamples)
            : samples
        let w = waveform.dataPointer.assumingMemoryBound(to: Float.self)
        var filled = 0
        while filled < Self.windowSamples {
            for s in clip.prefix(Self.windowSamples - filled) {
                w[filled] = s
                filled += 1
            }
        }
        do {
            let input = try MLDictionaryFeatureProvider(dictionary: ["waveform": waveform, "mask": mask])
            guard let output = try model.prediction(from: input).featureValue(for: "embedding")?.multiArrayValue else { return nil }
            let p = output.dataPointer.assumingMemoryBound(to: Float.self)
            return SpeakerTracker.normalized((0..<Self.dimensions).map { p[$0] })
        } catch {
            log.error("voiceprint failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
