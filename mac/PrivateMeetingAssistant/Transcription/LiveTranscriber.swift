import AVFoundation
import CoreMedia
import OSLog
import Speech
import Synchronization

private let log = Logger(subsystem: "dev.ruy.private-meeting-assistant", category: "live-transcript")

/// Words as they're spoken, for the live view: Apple's on-device streaming recognizer, fed the same
/// audio as Whisper. Its text appears within about half a second but is less accurate, so it's only
/// shown until Whisper's line for that stretch arrives, and never saved.
final class LiveTranscriber: Sendable {
    /// A stretch of recognized speech, in meeting milliseconds. Volatile text may still change.
    struct Fragment: Equatable, Sendable {
        let startMs: Int
        let endMs: Int
        let text: String
        let isFinal: Bool

        /// Whether Whisper's lines, reaching `reachMs`, replace this fragment: once they pass its middle.
        func isCovered(byWhisperReaching reachMs: Int) -> Bool { (startMs + endMs) / 2 <= reachMs }
    }

    private let input: AsyncStream<AnalyzerInput>.Continuation
    private let analyzer: SpeechAnalyzer
    private let results: Task<Void, Never>
    private let converter: Converter
    /// Where the audio fed so far ends. The recognizer stops at the first buffer that starts before
    /// it, and capture timestamps jitter by a few samples, so audio within `AudioFileRecorder`'s
    /// tolerance of it continues from there.
    private let next = Mutex<Int?>(nil)

    /// Starts recognizing in `locale` (or the nearest supported one), calling `onFragment` from a
    /// background task with each result. Nil if the language isn't supported or its model can't be
    /// installed now (it's downloaded the first time, by macOS, in the background).
    static func start(locale: Locale, onFragment: @escaping @Sendable (Fragment) -> Void) async -> LiveTranscriber? {
        guard SpeechTranscriber.isAvailable, let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            log.notice("live transcript: no on-device model for \(locale.identifier, privacy: .public)")
            return nil
        }
        let transcriber = SpeechTranscriber(
            locale: supported, transcriptionOptions: [], reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: [.audioTimeRange]
        )
        do {
            if await AssetInventory.status(forModules: [transcriber]) < .installed {
                try await AssetInventory.assetInstallationRequest(supporting: [transcriber])?.downloadAndInstall()
            }
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]),
                  let converter = Converter(to: format)
            else { return nil }
            let analyzer = SpeechAnalyzer(modules: [transcriber], options: .init(priority: .userInitiated, modelRetention: .lingering))
            try await analyzer.prepareToAnalyze(in: format)
            let (stream, input) = AsyncStream.makeStream(of: AnalyzerInput.self)
            try await analyzer.start(inputSequence: stream)
            log.notice("live transcript started (\(supported.identifier, privacy: .public), \(format.sampleRate, privacy: .public) Hz)")
            let results = Task.detached(priority: .userInitiated) {
                do {
                    for try await result in transcriber.results {
                        let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty else { continue }
                        onFragment(Fragment(
                            startMs: Int(result.range.start.seconds * 1000), endMs: Int(result.range.end.seconds * 1000),
                            text: text, isFinal: result.isFinal
                        ))
                    }
                } catch is CancellationError {
                    // Stopped with the recording.
                } catch {
                    log.error("live transcript stopped: \(error.localizedDescription, privacy: .public)")
                }
            }
            return LiveTranscriber(input: input, analyzer: analyzer, results: results, converter: converter)
        } catch {
            log.error("live transcript unavailable: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private init(input: AsyncStream<AnalyzerInput>.Continuation, analyzer: SpeechAnalyzer, results: Task<Void, Never>, converter: Converter) {
        self.input = input
        self.analyzer = analyzer
        self.results = results
        self.converter = converter
    }

    /// 16 kHz mono audio at a meeting sample position. Called from audio threads.
    func append(_ samples: [Float], at position: Int) {
        let position = next.withLock { next -> Int in
            var position = position
            if let expected = next, position < expected || position - expected <= AudioFileRecorder.continuityTolerance {
                position = expected
            }
            next = position + samples.count
            return position
        }
        guard let buffer = converter.convert(samples) else { return }
        let start = CMTime(value: CMTimeValue(position), timescale: CMTimeScale(MonoResampler.sampleRate))
        input.yield(AnalyzerInput(buffer: buffer, bufferStartTime: start))
    }

    /// Stops recognizing; what's still volatile is dropped (Whisper has the final say).
    func stop() async {
        input.finish()
        await analyzer.cancelAndFinishNow()
        results.cancel()
    }

    /// 16 kHz mono Float32 to the recognizer's format.
    private final class Converter: @unchecked Sendable {
        private let source = AVAudioFormat(standardFormatWithSampleRate: MonoResampler.sampleRate, channels: 1)!
        private let target: AVAudioFormat
        private let converter: AVAudioConverter
        /// Chunks from one source arrive on one audio thread, but the converter keeps state.
        private let lock = NSLock()

        init?(to target: AVAudioFormat) {
            guard let converter = AVAudioConverter(from: source, to: target) else { return nil }
            self.target = target
            self.converter = converter
        }

        func convert(_ samples: [Float]) -> AVAudioPCMBuffer? {
            guard !samples.isEmpty, let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(samples.count)) else { return nil }
            input.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { input.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
            if target == source { return input }
            let capacity = AVAudioFrameCount(Double(samples.count) * target.sampleRate / source.sampleRate) + 32
            guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
            lock.lock()
            defer { lock.unlock() }
            var fed = false
            var error: NSError?
            converter.convert(to: output, error: &error) { _, status in
                if fed {
                    status.pointee = .noDataNow
                    return nil
                }
                fed = true
                status.pointee = .haveData
                return input
            }
            return error == nil && output.frameLength > 0 ? output : nil
        }
    }
}
