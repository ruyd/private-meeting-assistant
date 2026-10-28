import SpeexDSP

/// Subtracts the far end's echo from the mic with SpeexDSP's adaptive (MDF) echo canceller.
/// Feed it time-aligned mic and far-end audio, 10 ms at a time. Not thread-safe.
final class EchoCanceller {
    /// Samples per call: 10 ms at 16 kHz.
    static let frameSize = 160
    /// The echo path it can model: 512 ms covers the ~300 ms speaker-to-mic delay plus room reverb.
    static let filterLength = 8_192

    private let state: OpaquePointer
    private var mic = [Int16](repeating: 0, count: frameSize)
    private var far = [Int16](repeating: 0, count: frameSize)
    private var out = [Int16](repeating: 0, count: frameSize)

    init(filterLength: Int = EchoCanceller.filterLength) {
        state = speex_echo_state_init(Int32(Self.frameSize), Int32(filterLength))
        var rate = Int32(MonoResampler.sampleRate)
        speex_echo_ctl(state, SPEEX_ECHO_SET_SAMPLING_RATE, &rate)
    }

    deinit {
        speex_echo_state_destroy(state)
    }

    /// Returns `mic` with the echo of `farEnd` removed. Both hold a multiple of `frameSize` samples
    /// covering the same moment.
    func cancel(mic micSamples: ArraySlice<Float>, farEnd farSamples: ArraySlice<Float>) -> [Float] {
        precondition(micSamples.count == farSamples.count && micSamples.count % Self.frameSize == 0)
        var result: [Float] = []
        result.reserveCapacity(micSamples.count)
        for offset in stride(from: 0, to: micSamples.count, by: Self.frameSize) {
            for i in 0..<Self.frameSize {
                mic[i] = Self.int16(micSamples[micSamples.startIndex + offset + i])
                far[i] = Self.int16(farSamples[farSamples.startIndex + offset + i])
            }
            speex_echo_cancellation(state, mic, far, &out)
            result += out.map { Float($0) / 32_768 }
        }
        return result
    }

    private static func int16(_ x: Float) -> Int16 {
        Int16(max(min(x * 32_768, 32_767), -32_768))
    }
}
