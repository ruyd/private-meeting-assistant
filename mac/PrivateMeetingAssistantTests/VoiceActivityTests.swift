import AVFoundation
import Foundation
import Testing
@testable import Private_Meeting_Assistant

struct VoiceActivityTests {
    private func speech() throws -> [Float] {
        let url = try #require(Bundle(for: VoiceActivityBundleToken.self).url(forResource: "jfk", withExtension: "wav"))
        let file = try AVAudioFile(forReading: url)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        return try MonoResampler().convert(buffer)
    }

    private func roomNoise(_ count: Int, seed: UInt32 = 9) -> [Float] {
        var seed = seed
        var low: Float = 0
        return (0..<count).map { _ in
            seed = seed &* 1_664_525 &+ 1_013_904_223
            let white = Float(seed) / Float(UInt32.max) * 2 - 1
            low = 0.97 * low + 0.03 * white
            return 0.002 * white + 0.05 * low
        }
    }

    /// Two seconds of noise before the words (where Whisper wrote "Gracias.") and three after are
    /// left out; the words are kept whole.
    @Test func keepsOnlyTheSpeech() throws {
        let vad = try #require(VoiceActivity.bundled())
        let voice = try speech()
        var audio = roomNoise(32_000 + voice.count + 48_000)
        for (i, v) in voice.enumerated() { audio[32_000 + i] += v }

        let ranges = vad.speechRanges(in: audio)
        print("speech ranges: \(ranges.map { "\(Double($0.lowerBound) / 16_000)-\(Double($0.upperBound) / 16_000)s" })")
        let first = try #require(ranges.first)
        let last = try #require(ranges.last)
        #expect(first.lowerBound >= 32_000 - 16_000, "most of the noise before the words is left out")
        #expect(first.lowerBound <= 32_000 + 8_000, "the words' start is kept")
        #expect(last.upperBound >= 32_000 + voice.count - 8_000, "the words' end is kept")
        #expect(last.upperBound <= 32_000 + voice.count + 24_000, "most of the noise after is left out")
    }

    @Test func noiseAloneHasNoSpeech() throws {
        let vad = try #require(VoiceActivity.bundled())
        #expect(vad.speechRanges(in: roomNoise(16_000 * 5)).isEmpty)
        #expect(vad.speechRanges(in: [Float](repeating: 0, count: 16_000)).isEmpty)
    }
}

private final class VoiceActivityBundleToken {}
