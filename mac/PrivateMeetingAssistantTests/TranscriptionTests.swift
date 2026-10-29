import AVFoundation
import Synchronization
import Testing
@testable import Private_Meeting_Assistant

struct NoiseMarkerTests {
    @Test func recognisesWhisperNoiseMarkers() {
        #expect(Transcriber.isNoiseMarker("[BLANK_AUDIO]"))
        #expect(Transcriber.isNoiseMarker("(upbeat music)"))
        #expect(Transcriber.isNoiseMarker("♪ ♪"))
        #expect(Transcriber.isNoiseMarker("  "))
        #expect(!Transcriber.isNoiseMarker("Hello there."))
        #expect(!Transcriber.isNoiseMarker("42"))
    }
}

/// Runs the real model, so it only runs once a speech model has been downloaded
/// (Settings, or `--prepare-model` in a debug build).
@Suite(.enabled(if: SpeechModel.catalog.contains(where: ModelStore.isComplete), "no speech model downloaded"))
struct TranscriptionPipelineTests {
    private func fixture() throws -> [Float] {
        let url = try #require(Bundle(for: BundleToken.self).url(forResource: "jfk", withExtension: "wav"))
        let file = try AVAudioFile(forReading: url)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        return try MonoResampler().convert(buffer)
    }

    @Test(.timeLimit(.minutes(10)))
    func jfkClipThroughPipeline() async throws {
        let model = try #require(
            ModelStore.isComplete(SpeechModel.recommended) ? SpeechModel.recommended : SpeechModel.catalog.first(where: ModelStore.isComplete)
        )
        let transcriber = try await Transcriber.load(model)

        // 0.8 s of room tone, the clip, then 1.5 s of room tone, delivered in 100 ms chunks like a capture.
        var seed: UInt32 = 11
        func roomTone(_ n: Int) -> [Float] {
            (0..<n).map { _ in
                seed = seed &* 1_664_525 &+ 1_013_904_223
                return (Float(seed) / Float(UInt32.max) * 2 - 1) * 0.0005
            }
        }
        let stream = roomTone(12_800) + (try fixture()) + roomTone(24_000)

        let lines = Mutex<[TranscriptLine]>([])
        let start = mach_absolute_time()
        let pipeline = TranscriptionPipeline(
            transcriber: transcriber, language: "en", startHostTime: start,
            onLine: { line in lines.withLock { $0.append(line) } },
            onBacklog: { _ in }
        )
        for offset in stride(from: 0, to: stream.count, by: 1_600) {
            let hostTime = start + AVAudioTime.hostTime(forSeconds: Double(offset) / 16_000)
            pipeline.append(AudioChunk(source: .system, samples: Array(stream[offset..<min(offset + 1_600, stream.count)]), hostTime: hostTime))
        }
        await pipeline.finish()

        let result = lines.withLock { $0 }
        let text = result.map(\.text).joined(separator: " ").lowercased()
        #expect(text.contains("ask not what your country can do for you"), "\(text)")
        #expect(result.allSatisfy { $0.source == .system })
        // Speech starts 0.8 s in; the segmenter keeps ~300 ms of pre-roll.
        let first = try #require(result.first)
        #expect((400...1300).contains(first.startMs), "first line at \(first.startMs) ms")
    }

    /// Loud, uneven noise the segmenter takes for speech (gusts of a fan and key clicks) never
    /// reaches Whisper: the voice activity model hears no one talking.
    @Test(.timeLimit(.minutes(5)))
    func noiseNeverReachesWhisper() async throws {
        #expect(VoiceActivity.bundled() != nil, "the app should ship the voice activity model")
        let model = try #require(SpeechModel.catalog.first(where: ModelStore.isComplete))
        let transcriber = try await Transcriber.load(model)
        var seed: UInt32 = 5
        func noise() -> Float {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return Float(seed) / Float(UInt32.max) * 2 - 1
        }
        var low: Float = 0
        var stream = (0..<(16_000 * 12)).map { i -> Float in
            low = 0.97 * low + 0.03 * noise()
            let gust = 0.5 + 0.5 * sin(Float(i) * 2 * .pi * 0.3 / 16_000) // swells every few seconds
            return 0.0005 * noise() + 0.2 * gust * low
        }
        var at = 8_000
        while at < stream.count - 800 {
            for k in 0..<800 { stream[at + k] += 0.2 * noise() * exp(-Float(k) / 90) }
            at += 3_000 + Int(abs(noise()) * 5_000)
        }
        let lines = Mutex<[TranscriptLine]>([])
        let start = mach_absolute_time()
        let pipeline = TranscriptionPipeline(
            transcriber: transcriber, language: "en", startHostTime: start, removeEcho: false,
            onLine: { line in lines.withLock { $0.append(line) } }, onBacklog: { _ in }
        )
        for offset in stride(from: 0, to: stream.count, by: 1_600) {
            let hostTime = start + AVAudioTime.hostTime(forSeconds: Double(offset) / 16_000)
            pipeline.append(AudioChunk(source: .mic, samples: Array(stream[offset..<min(offset + 1_600, stream.count)]), hostTime: hostTime))
        }
        await pipeline.finish()
        let result = lines.withLock { $0 }
        #expect(result.isEmpty, "\(result.map(\.text))")
    }

    /// Speech well below normal levels (about -45 dBFS, someone far from the mic) is still
    /// transcribed: dropping invented lines mustn't drop real ones.
    @Test(.timeLimit(.minutes(5)))
    func quietSpeechIsKept() async throws {
        let model = try #require(SpeechModel.catalog.first(where: ModelStore.isComplete))
        let transcriber = try await Transcriber.load(model)
        let clip = try fixture()
        let rms = (clip.reduce(0) { $0 + $1 * $1 } / Float(clip.count)).squareRoot()
        let quiet = clip.map { $0 * 0.0056 / rms }
        let lines = try await transcriber.transcribe(quiet, language: "en")
        for l in lines { print(String(format: "quiet: noSpeech %.2f confidence %.2f %@", l.noSpeech, l.confidence, l.text)) }
        #expect(lines.map(\.text).joined(separator: " ").lowercased().contains("ask not what your country can do for you"))
    }

    /// Room hum with keyboard clicks, the kind of noise that starts an utterance: Whisper tends to
    /// write "Thank you." over it, which must not reach the transcript.
    @Test(.timeLimit(.minutes(5)))
    func clicksAndHumAreNotTranscribed() async throws {
        let model = try #require(SpeechModel.catalog.first(where: ModelStore.isComplete))
        let transcriber = try await Transcriber.load(model)
        var seed: UInt32 = 7
        func noise() -> Float {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return Float(seed) / Float(UInt32.max) * 2 - 1
        }
        var audio = (0..<(16_000 * 6)).map { i in 0.002 * noise() + 0.003 * sin(Float(i) * 2 * .pi * 120 / 16_000) }
        // A key press every 150–400 ms: a sharp decaying click.
        var at = 3_000
        while at < audio.count - 800 {
            for k in 0..<800 { audio[at + k] += 0.25 * noise() * exp(-Float(k) / 90) }
            at += 2_400 + Int(abs(noise()) * 4_000)
        }
        let lines = try await transcriber.transcribe(audio, language: "en")
        #expect(lines.isEmpty, "\(lines.map { "\($0.text) (noSpeech \($0.noSpeech))" })")
    }
}

private final class BundleToken {}
