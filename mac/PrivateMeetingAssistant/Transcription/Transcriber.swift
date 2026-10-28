import Foundation
import WhisperKit

/// A loaded Whisper model. Not safe for concurrent use: callers transcribe one utterance at a time.
final class Transcriber: @unchecked Sendable {
    struct Line: Equatable, Sendable {
        /// Seconds from the start of the transcribed audio.
        let start: Float
        let end: Float
        let text: String
    }

    /// Segments Whisper is this sure contain no speech are dropped.
    static let noSpeechThreshold: Float = 0.6

    let model: SpeechModel
    private let whisper: WhisperKit

    private init(model: SpeechModel, whisper: WhisperKit) {
        self.model = model
        self.whisper = whisper
    }

    /// Loads (and on first use, compiles for this Mac's Neural Engine) a downloaded model.
    /// The first load also fetches the model's tokenizer from Hugging Face and caches it.
    static func load(_ model: SpeechModel) async throws -> Transcriber {
        let config = WhisperKitConfig(
            downloadBase: ModelStore.downloadBase,
            modelFolder: ModelStore.folder(for: model).path,
            tokenizerFolder: ModelStore.downloadBase,
            verbose: false,
            logLevel: .none,
            prewarm: true,
            load: true,
            download: false
        )
        return Transcriber(model: model, whisper: try await WhisperKit(config))
    }

    /// `language` is an ISO code, or nil to detect it. English-only models always use English.
    func transcribe(_ samples: [Float], language: String?) async throws -> [Line] {
        let language = model.englishOnly ? "en" : language
        let options = DecodingOptions(
            language: language,
            temperatureFallbackCount: 3,
            detectLanguage: language == nil,
            skipSpecialTokens: true,
            suppressBlank: true,
            noSpeechThreshold: Self.noSpeechThreshold
        )
        let results = try await whisper.transcribe(audioArray: samples, decodeOptions: options)
        return results.flatMap(\.segments)
            .filter { $0.noSpeechProb < Self.noSpeechThreshold }
            .map { Line(start: $0.start, end: $0.end, text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { !Self.isNoiseMarker($0.text) }
    }

    /// Whisper's descriptions of non-speech, e.g. "[BLANK_AUDIO]", "(upbeat music)" or "♪ ♪".
    static func isNoiseMarker(_ text: String) -> Bool {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty
            || (s.hasPrefix("[") && s.hasSuffix("]"))
            || (s.hasPrefix("(") && s.hasSuffix(")"))
            || !s.contains(where: { $0.isLetter || $0.isNumber })
    }
}
