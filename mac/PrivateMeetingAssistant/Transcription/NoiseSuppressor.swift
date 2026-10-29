import SpeexDSP

/// Turns steady background noise down (a fan, air conditioning, a computer's hum) in every
/// frequency band while letting speech through, with SpeexDSP's preprocessor: it learns the noise's
/// spectrum from the quiet moments and lowers each band by how much of it is noise. The low-cut filter
/// takes the rumble under voices; this takes the noise among them, which with a fan above the mic sat
/// at 100–1000 Hz, where voices are.
///
/// Takes 16 kHz mono chunks of any length, at meeting sample positions, and returns whole 10 ms
/// frames, so up to one frame waits for the next chunk. Silence (gated echo) passes untouched, so
/// the noise it learned stays the room's. Not thread-safe.
final class NoiseSuppressor {
    /// The most the noise is turned down, in dB.
    static let maxSuppression: Int32 = -20
    private static let frameSize = EchoCanceller.frameSize

    private let state: OpaquePointer
    private var held: [Float] = []
    /// Meeting position of `held[0]`.
    private var heldAt = 0
    private var frame = [Int16](repeating: 0, count: frameSize)

    init?(maxSuppression: Int32 = NoiseSuppressor.maxSuppression) {
        guard let state = speex_preprocess_state_init(Int32(Self.frameSize), Int32(MonoResampler.sampleRate)) else { return nil }
        self.state = state
        var on: Int32 = 1, off: Int32 = 0, suppression = maxSuppression
        speex_preprocess_ctl(state, SPEEX_PREPROCESS_SET_DENOISE, &on)
        speex_preprocess_ctl(state, SPEEX_PREPROCESS_SET_NOISE_SUPPRESS, &suppression)
        speex_preprocess_ctl(state, SPEEX_PREPROCESS_SET_AGC, &off)
        speex_preprocess_ctl(state, SPEEX_PREPROCESS_SET_VAD, &off)
        speex_preprocess_ctl(state, SPEEX_PREPROCESS_SET_DEREVERB, &off)
    }

    deinit {
        speex_preprocess_state_destroy(state)
    }

    /// The audio up to the last whole frame, with noise turned down, and the meeting position it
    /// starts at. After a gap (or overlap) in positions, the part frame held from before is dropped.
    func process(_ samples: [Float], at position: Int) -> (samples: [Float], position: Int) {
        if position != heldAt + held.count {
            held = []
            heldAt = position
        }
        held += samples
        let whole = held.count / Self.frameSize * Self.frameSize
        var out: [Float] = []
        out.reserveCapacity(whole)
        for start in stride(from: 0, to: whole, by: Self.frameSize) {
            let chunk = held[start..<(start + Self.frameSize)]
            if chunk.allSatisfy({ $0 == 0 }) {
                out += chunk
                continue
            }
            for (i, s) in chunk.enumerated() { frame[i] = Int16(max(min(s * 32_768, 32_767), -32_768)) }
            speex_preprocess_run(state, &frame)
            out += frame.map { Float($0) / 32_768 }
        }
        let at = heldAt
        held.removeFirst(whole)
        heldAt += whole
        return (out, at)
    }
}
