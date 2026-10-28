import Foundation
import Testing
@testable import Private_Meeting_Assistant

struct EchoGateTests {
    static let rate = 16_000

    /// Syllable-like bursts between `from` and `to` seconds, silent elsewhere: harmonics of a pitch
    /// (`voice`, in Hz) up to 4 kHz plus a little breath noise. Broadband enough for an adaptive echo
    /// canceller to learn from, and voices with different pitches sit in different bands, as real
    /// ones do, which per-band echo suppression relies on.
    static func speech(voice: UInt32, amp: Float, from: Double, to: Double, seconds: Double) -> [Float] {
        let f0 = Float(voice)
        let harmonics = Int(4_000 / f0)
        var seed = voice
        return (0..<Int(seconds * Double(rate))).map { i in
            seed = seed &* 1_664_525 &+ 1_013_904_223
            let t = Double(i) / Double(rate)
            guard t >= from, t < to, (t - from).truncatingRemainder(dividingBy: 0.35) < 0.25 else { return 0 }
            var x: Float = 0
            for k in 1...harmonics { x += sin(2 * .pi * f0 * Float(k) * Float(i) / Float(rate)) / Float(k) }
            return amp * (0.6 * x + 0.1 * (Float(seed) / Float(UInt32.max) * 2 - 1))
        }
    }

    static func delayed(_ x: [Float], by seconds: Double, gain: Float) -> [Float] {
        let d = Int(seconds * Double(rate))
        return (0..<x.count).map { $0 >= d ? x[$0 - d] * gain : 0 }
    }

    static func noise(_ n: Int, amp: Float) -> [Float] {
        var seed: UInt32 = 9
        return (0..<n).map { _ in
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return (Float(seed) / Float(UInt32.max) * 2 - 1) * amp
        }
    }

    /// Feeds far end and mic in 100 ms chunks, as the captures deliver them, and returns the gated mic.
    /// The gate's own logic, with the canceller but no band suppression, gating throughout.
    static let gateStages = EchoGate.Stages(cancel: true, suppressResidual: false, gate: true, gateOnlyWhileLearning: false)

    static func run(farEnd: [Float], mic: [Float], stages: EchoGate.Stages = gateStages) -> [Float] {
        var gate = EchoGate(stages: stages)
        var out = [Float](repeating: .nan, count: mic.count)
        func place(_ o: EchoGate.Output?) {
            guard let o else { return }
            for (i, s) in o.samples.enumerated() where o.position + i < out.count { out[o.position + i] = s }
        }
        for start in stride(from: 0, to: mic.count, by: 1_600) {
            let end = min(start + 1_600, mic.count)
            gate.addFarEnd(Array(farEnd[start..<end]), at: start)
            place(gate.processMic(Array(mic[start..<end]), at: start))
        }
        place(gate.flush())
        #expect(out.allSatisfy { !$0.isNaN }, "every mic sample comes out exactly once")
        return out
    }

    static func power(_ x: [Float], from: Double, to: Double) -> Float {
        let slice = x[Int(from * Double(rate))..<Int(to * Double(rate))]
        return slice.reduce(0) { $0 + $1 * $1 } / Float(slice.count)
    }

    static func db(_ ratio: Float) -> Float { 10 * log10(max(ratio, 1e-12)) }

    @Test func suppressesEchoOfTheFarEnd() {
        let seconds = 6.0
        let far = Self.speech(voice: 110, amp: 0.2, from: 1, to: 5, seconds: seconds)
        // The echo is louder than the tap's signal, as with laptop speakers turned up.
        let mic = zip(Self.delayed(far, by: 0.27, gain: 2.5), Self.noise(far.count, amp: 0.0005)).map(+)
        let out = Self.run(farEnd: far, mic: mic)

        // Once learned (about a second into the far end talking), echo drops by at least 20 dB.
        let reduction = Self.db(Self.power(out, from: 2.2, to: 5.2) / Self.power(mic, from: 2.2, to: 5.2))
        #expect(reduction < -20, "echo reduced by only \(-reduction) dB")

        // And none of it becomes a "Me" utterance once learned.
        var segmenter = Segmenter()
        var utterances = segmenter.push(out)
        if let last = segmenter.flush() { utterances.append(last) }
        #expect(utterances.allSatisfy { $0.startMs < 2_200 }, "\(utterances.map(\.startMs))")
    }

    @Test func passesNearEndSpeechUntouched() {
        let near = Self.speech(voice: 210, amp: 0.2, from: 0.5, to: 2.5, seconds: 3)
        let mic = zip(near, Self.noise(near.count, amp: 0.0005)).map(+)
        let out = Self.run(farEnd: [Float](repeating: 0, count: mic.count), mic: mic)
        #expect(out == mic)
    }

    @Test func passesYouTalkingOverTheFarEnd() {
        let seconds = 6.0
        let far = Self.speech(voice: 110, amp: 0.2, from: 0.5, to: 6, seconds: seconds)
        let echo = Self.delayed(far, by: 0.27, gain: 0.3)
        let near = Self.speech(voice: 210, amp: 0.25, from: 3, to: 4.5, seconds: seconds)
        let mic = zip(zip(echo, near).map(+), Self.noise(far.count, amp: 0.0005)).map(+)
        let out = Self.run(farEnd: far, mic: mic)

        // Your words keep nearly all their energy (> -1 dB) even with the far end talking.
        let kept = Self.db(Self.power(out, from: 3, to: 4.5) / Self.power(mic, from: 3, to: 4.5))
        #expect(kept > -1, "near-end speech lost \(-kept) dB")
        // While only the far end talks (once learned, about a second in), its echo is still removed.
        #expect(Self.db(Self.power(out, from: 2, to: 2.9) / Self.power(mic, from: 2, to: 2.9)) < -20)
    }

    @Test func headphonesMeanNothingToGate() {
        // No echo reaches the mic, so the far end's level says nothing about the mic: you pass.
        let seconds = 5.0
        let far = Self.speech(voice: 110, amp: 0.2, from: 0.5, to: 5, seconds: seconds)
        let near = Self.speech(voice: 210, amp: 0.05, from: 2.5, to: 4, seconds: seconds)
        let mic = zip(near, Self.noise(far.count, amp: 0.0005)).map(+)
        let out = Self.run(farEnd: far, mic: mic)
        let kept = Self.db(Self.power(out, from: 2.5, to: 4) / Self.power(mic, from: 2.5, to: 4))
        #expect(kept > -1, "near-end speech lost \(-kept) dB")
    }

    // The default chain: canceller and per-band suppression, gating only while they converge.

    /// Gating covers the first seconds while the canceller converges; band suppression then takes
    /// over. On a steady synthetic pitch it removes far less than on real speech (whose pitch and
    /// spectrum keep moving), so this only checks it doesn't fall apart; the replay test on a real
    /// recording, and the transcript-level filter, cover the rest.
    @Test func defaultStagesRemoveEcho() {
        let far = Self.speech(voice: 110, amp: 0.2, from: 1, to: 9, seconds: 10)
        let mic = zip(Self.delayed(far, by: 0.27, gain: 2.5), Self.noise(far.count, amp: 0.0005)).map(+)
        let out = Self.run(farEnd: far, mic: mic, stages: .init())
        let learning = Self.db(Self.power(out, from: 2.2, to: 3.8) / Self.power(mic, from: 2.2, to: 3.8))
        #expect(learning < -40, "echo reduced by only \(-learning) dB while gating")
        let settled = Self.db(Self.power(out, from: 5, to: 9) / Self.power(mic, from: 5, to: 9))
        #expect(settled < -10, "echo reduced by only \(-settled) dB once settled")
    }

    @Test func defaultStagesKeepYourVoiceOverTheFarEnd() {
        let far = Self.speech(voice: 110, amp: 0.2, from: 0.5, to: 12, seconds: 12)
        let echo = Self.delayed(far, by: 0.27, gain: 0.5)
        // You start after the chain has settled, at about the echo's loudness.
        let near = Self.speech(voice: 210, amp: 0.1, from: 8, to: 10, seconds: 12)
        let mic = zip(zip(echo, near).map(+), Self.noise(far.count, amp: 0.0005)).map(+)
        let out = Self.run(farEnd: far, mic: mic, stages: .init())
        // Energy of your voice that survives, measured by projecting the output onto it.
        let r = (8 * Self.rate)..<(10 * Self.rate)
        let kept = r.reduce(Float(0)) { $0 + out[$1] * near[$1] } / r.reduce(Float(0)) { $0 + near[$1] * near[$1] }
        #expect(kept > 0.5, "kept only \(Int(kept * 100))% of your voice")
    }

    @Test func defaultStagesPassNearEndSpeechAlone() {
        let near = Self.speech(voice: 210, amp: 0.2, from: 0.5, to: 2.5, seconds: 3)
        let mic = zip(near, Self.noise(near.count, amp: 0.0005)).map(+)
        let out = Self.run(farEnd: [Float](repeating: 0, count: mic.count), mic: mic, stages: .init())
        #expect(out == mic)
    }
}
