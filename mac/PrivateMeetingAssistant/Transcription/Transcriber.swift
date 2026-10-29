import Foundation
import Synchronization
import whisper

/// A loaded Whisper model, run by whisper.cpp on this Mac's GPU (Metal). Loading reads the model file
/// directly, with no per-Mac compile step, so it takes well under a second once the file is in the
/// disk cache. Not safe for concurrent use: callers transcribe one utterance at a time.
final class Transcriber: @unchecked Sendable {
    struct Line: Equatable, Sendable {
        /// Seconds from the start of the transcribed audio.
        let start: Float
        let end: Float
        let text: String
        /// Whisper's mean probability for the line's words (0…1).
        var confidence: Float = 1
        /// Whisper's estimate that the audio held no speech (0…1).
        var noSpeech: Float = 0
    }

    /// Segments Whisper thinks this likely contain no speech are dropped. Over room noise and
    /// keyboard clicks it writes stock phrases ("Thank you.", "I'm going to go ahead…") with 0.3–0.6;
    /// speech, even quiet, stays under 0.1.
    static let noSpeechThreshold: Float = 0.3
    /// whisper.cpp rejects input shorter than a second; shorter utterances are padded with silence.
    private static let minimumSamples = 17_600

    let model: SpeechModel
    private let handle: Handle
    private var context: OpaquePointer { handle.context }
    private var state: OpaquePointer { handle.state }
    private let threads = Int32(min(8, ProcessInfo.processInfo.activeProcessorCount))

    private init(model: SpeechModel, handle: Handle) {
        self.model = model
        self.handle = handle
    }

    deinit {
        handle.free()
    }

    /// whisper.cpp's memory for one loaded model, freed exactly once: when its transcriber goes away,
    /// or when the process exits. ggml aborts the process at exit if any of its Metal memory is still
    /// in use, and the app keeps a model loaded until it quits (or quits while one is loading).
    private final class Handle: @unchecked Sendable {
        let context: OpaquePointer
        let state: OpaquePointer
        /// whisper.cpp blocks while it works; this keeps it off Swift's shared threads.
        let queue = DispatchQueue(label: "dev.ruy.private-meeting-assistant.whisper", qos: .userInitiated)
        private let freed = Mutex(false)

        /// Loaded models not yet freed, for the exit handler.
        static let live = Mutex<[ObjectIdentifier: Handle]>([:])
        /// Models being loaded right now. One still loading holds Metal memory too and can't be freed
        /// mid-load (nor waited for once exit has begun), so quitting waits for it (see `AppDelegate`).
        static let loading = Mutex(0)

        /// Sets up ggml's devices, which registers ggml's own cleanup at exit, then registers ours,
        /// so ours runs first (exit handlers run newest first).
        static let prepared: Void = {
            _ = ggml_backend_dev_count()
            atexit {
                for handle in Handle.live.withLock({ Array($0.values) }) {
                    handle.queue.sync {} // let a transcription that's under way finish
                    handle.free()
                }
            }
        }()

        init(context: OpaquePointer, state: OpaquePointer) {
            self.context = context
            self.state = state
            Self.live.withLock { $0[ObjectIdentifier(self)] = self }
        }

        func free() {
            guard freed.withLock({ freed in defer { freed = true }; return !freed }) else { return }
            Self.live.withLock { $0[ObjectIdentifier(self)] = nil }
            whisper_free_state(state)
            whisper_free(context)
        }
    }

    /// Whether a model is being loaded right now.
    static var isLoading: Bool { Handle.loading.withLock { $0 } > 0 }

    /// Waits (up to `limit`) until no model is being loaded, e.g. before the app quits.
    static func waitForLoads(limit: Duration = .seconds(5)) async {
        let clock = ContinuousClock()
        let deadline = clock.now + limit
        while isLoading, clock.now < deadline { try? await Task.sleep(for: .milliseconds(20)) }
    }

    /// Loads a downloaded model onto the GPU.
    static func load(_ model: SpeechModel) async throws -> Transcriber {
        try await Task.detached(priority: .userInitiated) {
            // whisper.cpp and ggml otherwise log every step to stderr.
            whisper_log_set({ _, _, _ in }, nil)
            _ = Handle.prepared
            Handle.loading.withLock { $0 += 1 }
            // Counted until the model is registered for freeing (or failed to load).
            defer { Handle.loading.withLock { $0 -= 1 } }
            var params = whisper_context_default_params()
            params.use_gpu = true
            params.flash_attn = true
            guard let context = whisper_init_from_file_with_params(ModelStore.file(for: model).path, params) else {
                throw TranscriberError.couldNotLoad(model.name)
            }
            guard let state = whisper_init_state(context) else {
                whisper_free(context)
                throw TranscriberError.couldNotLoad(model.name)
            }
            return Transcriber(model: model, handle: Handle(context: context, state: state))
        }.value
    }

    /// `language` is an ISO code, or nil to detect it. English-only models always use English.
    func transcribe(_ samples: [Float], language: String?) async throws -> [Line] {
        let language = model.englishOnly ? "en" : (language ?? "auto")
        return try await withCheckedThrowingContinuation { continuation in
            handle.queue.async {
                continuation.resume(with: Result { try self.run(samples, language: language) })
            }
        }
    }

    private func run(_ samples: [Float], language: String) throws -> [Line] {
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.n_threads = threads
        // Each utterance stands alone: carrying text over makes Whisper repeat itself after silences.
        params.no_context = true
        params.suppress_blank = true
        params.suppress_nst = true
        params.no_speech_thold = Self.noSpeechThreshold
        params.print_progress = false
        params.print_realtime = false
        params.print_timestamps = false
        params.print_special = false

        var input = samples
        if input.count < Self.minimumSamples { input += [Float](repeating: 0, count: Self.minimumSamples - input.count) }

        let status = language.withCString { code in
            params.language = code
            return input.withUnsafeBufferPointer { whisper_full_with_state(context, state, params, $0.baseAddress, Int32($0.count)) }
        }
        guard status == 0 else { throw TranscriberError.failed(status) }

        let trace = ProcessInfo.processInfo.environment["PMA_TRACE_SEGMENTS"] != nil
        var previous: String?
        return (0..<whisper_full_n_segments_from_state(state)).compactMap { i in
            let text = String(cString: whisper_full_get_segment_text_from_state(state, i))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let noSpeech = whisper_full_get_segment_no_speech_prob_from_state(state, i)
            let confidence = meanTokenProbability(segment: i)
            if trace { print(String(format: "segment: noSpeech %.2f confidence %.2f %@", noSpeech, confidence, text)) }
            guard noSpeech < Self.noSpeechThreshold, !Self.isNoiseMarker(text) else { return nil }
            // Stuck in a loop: the same sentence again and again.
            guard text != previous else { return nil }
            previous = text
            // Timestamps are in hundredths of a second.
            return Line(
                start: Float(whisper_full_get_segment_t0_from_state(state, i)) / 100,
                end: Float(whisper_full_get_segment_t1_from_state(state, i)) / 100,
                text: text, confidence: confidence, noSpeech: noSpeech
            )
        }
    }

    /// The mean probability of a segment's text tokens (timestamps and other special tokens left out).
    private func meanTokenProbability(segment i: Int32) -> Float {
        let firstSpecial = whisper_token_eot(context)
        var sum: Float = 0
        var count = 0
        for j in 0..<whisper_full_n_tokens_from_state(state, i) {
            let token = whisper_full_get_token_data_from_state(state, i, j)
            guard token.id < firstSpecial else { continue }
            sum += token.p
            count += 1
        }
        return count == 0 ? 0 : sum / Float(count)
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

enum TranscriberError: LocalizedError {
    case couldNotLoad(String)
    case failed(Int32)

    var errorDescription: String? {
        switch self {
        case .couldNotLoad(let name): "\(name) couldn't be loaded. Its file may be damaged: remove it in Settings and download it again."
        case .failed(let code): "Transcription failed (whisper.cpp error \(code))."
        }
    }
}
