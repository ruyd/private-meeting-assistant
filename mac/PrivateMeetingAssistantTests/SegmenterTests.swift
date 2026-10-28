import Foundation
import Testing
@testable import Private_Meeting_Assistant

/// Ported from the Tauri prototype's vad.rs tests, plus gap handling.
struct SegmenterTests {
    private func noise(_ n: Int, amp: Float, seed: inout UInt32) -> [Float] {
        (0..<n).map { _ in
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return (Float(seed) / Float(UInt32.max) * 2 - 1) * amp
        }
    }

    private func voice(_ n: Int) -> [Float] {
        (0..<n).map { 0.3 * sin(2 * .pi * 220 * Float($0) / 16_000) }
    }

    private func run(_ stream: [Float], chunk: Int, _ seg: inout Segmenter) -> [Segmenter.Utterance] {
        var out: [Segmenter.Utterance] = []
        for start in stride(from: 0, to: stream.count, by: chunk) {
            out += seg.push(Array(stream[start..<min(start + chunk, stream.count)]))
        }
        if let last = seg.flush() { out.append(last) }
        return out
    }

    @Test func splitsTwoUtterancesOnPause() {
        var seed: UInt32 = 7
        var stream = noise(16_000, amp: 0.0005, seed: &seed) // 1 s room tone
        stream += voice(24_000) // 1.5 s speech at t=1.0
        stream += noise(24_000, amp: 0.0005, seed: &seed) // 1.5 s pause
        stream += voice(16_000) // 1 s speech at t=4.0
        stream += noise(16_000, amp: 0.0005, seed: &seed)

        var seg = Segmenter()
        let utts = run(stream, chunk: 1_000, &seg)
        #expect(utts.count == 2)
        // Starts include ~300 ms pre-roll.
        #expect((650...1000).contains(utts[0].startMs))
        #expect((3650...4000).contains(utts[1].startMs))
        #expect(utts[0].endMs < 3_000)
    }

    @Test func ignoresSilenceAndBlips() {
        var seed: UInt32 = 3
        var stream = noise(32_000, amp: 0.0005, seed: &seed)
        stream += voice(1_600) // 100 ms click
        stream += noise(32_000, amp: 0.0005, seed: &seed)
        var seg = Segmenter()
        #expect(run(stream, chunk: 777, &seg).isEmpty)
    }

    @Test func forcesCutOnLongMonologue() {
        var seg = Segmenter()
        let utts = run(voice(16_000 * 40), chunk: 4_000, &seg)
        #expect(utts.count >= 3)
        #expect(utts.allSatisfy { $0.samples.count <= 16_000 * 16 })
    }

    @Test func gapEndsUtteranceAndKeepsAbsoluteTime() {
        var seed: UInt32 = 5
        var seg = Segmenter()
        var utts = seg.push(noise(8_000, amp: 0.0005, seed: &seed) + voice(16_000))
        // Delivery stops mid-speech, then resumes 10 s into the stream.
        if let ended = seg.skip(to: 160_000) { utts.append(ended) }
        #expect(utts.count == 1)
        #expect(seg.position == 160_000)
        utts = run(voice(16_000) + noise(16_000, amp: 0.0005, seed: &seed), chunk: 1_000, &seg)
        #expect(utts.count == 1)
        #expect((10_000...10_100).contains(utts[0].startMs))
    }
}
