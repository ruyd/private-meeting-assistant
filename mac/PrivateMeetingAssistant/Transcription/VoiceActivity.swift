import CoreML
import Foundation
import OSLog

private let log = Logger(subsystem: "dev.ruy.private-meeting-assistant", category: "transcription")

/// Whether audio holds someone talking: Silero VAD (v6, MIT), as converted to Core ML by Fluid
/// Inference. Unlike the segmenter's loudness test it tells a voice from a fan, keyboard clicks or a
/// quiet room, which Whisper writes "Thank you." over.
///
/// Gives a speech probability for every 32 ms (512 samples at 16 kHz), seeing the 64 samples before
/// each chunk and carrying its memory from one chunk to the next. Not thread-safe: the transcription
/// worker uses it, one utterance at a time.
///
/// Measured on recordings with room noise and keyboard clicks, a fan above the mic and a quiet room:
/// every stretch Whisper invented a line over scored at most 0.38, every one with speech 0.97 or more.
final class VoiceActivity: @unchecked Sendable {
    static let chunk = 512
    /// A chunk this likely to be speech counts as speech…
    static let threshold: Float = 0.5
    /// …and an utterance needs this many such chunks (about 0.1 s) to be worth transcribing.
    static let minSpeechChunks = 3
    private static let context = 64
    private static let stateSize = 128

    private let model: MLModel
    private let audio: MLMultiArray
    private var hidden: MLMultiArray
    private var cell: MLMultiArray
    private var tail = [Float](repeating: 0, count: VoiceActivity.context)

    init(model: MLModel) throws {
        self.model = model
        audio = try MLMultiArray(shape: [1, (Self.context + Self.chunk) as NSNumber], dataType: .float32)
        hidden = try MLMultiArray(shape: [1, Self.stateSize as NSNumber], dataType: .float32)
        cell = try MLMultiArray(shape: [1, Self.stateSize as NSNumber], dataType: .float32)
        reset()
    }

    /// The model that ships with the app.
    static func bundled() -> VoiceActivity? {
        guard let url = Bundle.main.url(forResource: "silero-vad", withExtension: "mlmodelc") else {
            log.error("the voice activity model is missing from the app")
            return nil
        }
        return load(from: url)
    }

    static func load(from url: URL) -> VoiceActivity? {
        do {
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .cpuOnly // tiny; the GPU is busy with Whisper
            return try VoiceActivity(model: MLModel(contentsOf: url, configuration: configuration))
        } catch {
            log.error("couldn't load the voice activity model: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Whether someone is talking anywhere in `samples` (judged afresh).
    func hasSpeech(_ samples: [Float]) -> Bool {
        reset()
        return probabilities(samples[...]).filter { $0 >= Self.threshold }.count >= Self.minSpeechChunks
    }

    /// Forgets what it heard, for a new stretch of audio.
    func reset() {
        for array in [hidden, cell] {
            array.dataPointer.assumingMemoryBound(to: Float.self).update(repeating: 0, count: Self.stateSize)
        }
        tail = [Float](repeating: 0, count: Self.context)
    }

    /// The speech probability of each whole 32 ms chunk of `samples` (a partial last chunk is left out).
    func probabilities(_ samples: ArraySlice<Float>) -> [Float] {
        var out: [Float] = []
        var start = samples.startIndex
        while start + Self.chunk <= samples.endIndex {
            let chunk = samples[start..<(start + Self.chunk)]
            let a = audio.dataPointer.assumingMemoryBound(to: Float.self)
            for (i, s) in (tail + chunk).enumerated() { a[i] = s }
            tail = Array(chunk.suffix(Self.context))
            do {
                let result = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: [
                    "audio_input": audio, "hidden_state": hidden, "cell_state": cell,
                ]))
                guard let p = result.featureValue(for: "vad_output")?.multiArrayValue,
                      let h = result.featureValue(for: "new_hidden_state")?.multiArrayValue,
                      let c = result.featureValue(for: "new_cell_state")?.multiArrayValue
                else { break }
                out.append(p[0].floatValue)
                hidden = h
                cell = c
            } catch {
                log.error("voice activity failed: \(error.localizedDescription, privacy: .public)")
                break
            }
            start += Self.chunk
        }
        return out
    }
}
