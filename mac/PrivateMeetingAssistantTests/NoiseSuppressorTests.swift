import AVFoundation
import Foundation
import Testing
@testable import Private_Meeting_Assistant

struct NoiseSuppressorTests {
    /// Fan-like noise: broadband hiss shaped toward the low end, steady.
    private func fanNoise(seconds: Double, seed: UInt32 = 3) -> [Float] {
        var seed = seed
        var low: Float = 0
        return (0..<Int(16_000 * seconds)).map { _ in
            seed = seed &* 1_664_525 &+ 1_013_904_223
            let white = Float(seed) / Float(UInt32.max) * 2 - 1
            low = 0.95 * low + 0.05 * white
            return 0.01 * (white * 0.3 + low * 4)
        }
    }

    private func speech() throws -> [Float] {
        let url = try #require(Bundle(for: SuppressorBundleToken.self).url(forResource: "jfk", withExtension: "wav"))
        let file = try AVAudioFile(forReading: url)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        return try MonoResampler().convert(buffer)
    }

    private func db(_ x: ArraySlice<Float>) -> Double {
        10 * log10(max(x.reduce(0) { $0 + Double($1 * $1) } / Double(max(x.count, 1)), 1e-12))
    }

    /// Feeds 100 ms chunks like a capture; checks positions run on without gaps.
    private func run(_ input: [Float], _ suppressor: NoiseSuppressor) -> [Float] {
        var out: [Float] = []
        for offset in stride(from: 0, to: input.count, by: 1_600) {
            let (samples, position) = suppressor.process(Array(input[offset..<min(offset + 1_600, input.count)]), at: offset)
            #expect(position == out.count)
            out += samples
        }
        return out
    }

    @Test func turnsSteadyNoiseDownAndKeepsSpeech() throws {
        let voice = try speech()
        let noise = fanNoise(seconds: 4 + Double(voice.count) / 16_000)
        // 4 s of the fan alone, then someone talking over it.
        var input = noise
        for (i, v) in voice.enumerated() { input[64_000 + i] += v }
        let output = run(input, try #require(NoiseSuppressor()))

        let fanBefore = db(input[32_000..<64_000]), fanAfter = db(output[32_000..<64_000])
        let speechBefore = db(input[64_000..<(64_000 + voice.count)]), speechAfter = db(output[64_000..<min(64_000 + voice.count, output.count)])
        print(String(format: "noise suppressor: fan %.1f → %.1f dB, speech over it %.1f → %.1f dB", fanBefore, fanAfter, speechBefore, speechAfter))
        #expect(fanBefore - fanAfter > 12, "the fan should come down a lot")
        #expect(speechBefore - speechAfter < 3, "speech should keep its level")
    }

    @Test func silencePassesUntouched() throws {
        let suppressor = try #require(NoiseSuppressor())
        _ = run(fanNoise(seconds: 2), suppressor)
        let (out, _) = suppressor.process([Float](repeating: 0, count: 1_600), at: 32_000)
        #expect(out.allSatisfy { $0 == 0 })
    }

    @Test func startsOverAfterAGap() throws {
        let suppressor = try #require(NoiseSuppressor())
        _ = suppressor.process([Float](repeating: 0.01, count: 1_650), at: 0) // 50 samples held
        let (out, position) = suppressor.process([Float](repeating: 0.01, count: 1_600), at: 10_000)
        #expect(position == 10_000)
        #expect(out.count == 1_600)
    }
}

private final class SuppressorBundleToken {}
