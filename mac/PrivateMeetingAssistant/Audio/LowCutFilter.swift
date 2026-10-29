import Foundation

/// Takes out rumble below voices: fans, air conditioning, desk bumps, handling noise. A fan above
/// the mic had most of its noise below 100 Hz, and cutting it (-31 to -41 dBFS) means fewer noise
/// stretches pass for speech and start utterances Whisper writes "Thank you." over. Voices are
/// barely touched: even low ones have little energy below 100 Hz.
///
/// A 4th-order Butterworth high-pass (two biquads) on 16 kHz mono, keeping its state from one chunk
/// to the next. Not thread-safe: one per stream.
final class LowCutFilter {
    static let cutoff: Double = 100

    private struct Biquad {
        let b0, b1, b2, a1, a2: Float
        var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0

        /// A high-pass section (Audio EQ Cookbook).
        init(cutoff: Double, q: Double, sampleRate: Double) {
            let w = 2 * Double.pi * cutoff / sampleRate
            let alpha = sin(w) / (2 * q)
            let a0 = 1 + alpha
            b0 = Float((1 + cos(w)) / 2 / a0)
            b1 = Float(-(1 + cos(w)) / a0)
            b2 = b0
            a1 = Float(-2 * cos(w) / a0)
            a2 = Float((1 - alpha) / a0)
        }

        mutating func process(_ x: Float) -> Float {
            let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1
            x1 = x
            y2 = y1
            y1 = y
            return y
        }
    }

    // Butterworth: the two sections' Qs for 4th order.
    private var sections: [Biquad]

    /// For 16 kHz audio unless told otherwise (the saved audio's full-quality mic is 48 kHz).
    init(sampleRate: Double = MonoResampler.sampleRate) {
        sections = [0.5412, 1.3066].map { Biquad(cutoff: LowCutFilter.cutoff, q: $0, sampleRate: sampleRate) }
    }

    func process(_ samples: [Float]) -> [Float] {
        var out = samples
        for i in out.indices {
            var y = out[i]
            for s in sections.indices { y = sections[s].process(y) }
            out[i] = y
        }
        return out
    }
}
