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
}

private final class BundleToken {}
