import SpeexDSP

/// Subtracts the far end's echo from the mic with SpeexDSP's adaptive (MDF) echo canceller, then
/// optionally suppresses the echo it couldn't remove with SpeexDSP's preprocessor, per frequency band:
/// bands where your voice dominates are kept, bands that are mostly leftover echo are turned down.
/// Feed it time-aligned mic and far-end audio, 10 ms at a time. Not thread-safe.
final class EchoCanceller {
    /// Samples per call: 10 ms at 16 kHz.
    static let frameSize = 160
    /// The echo path it can model: 512 ms covers the ~300 ms speaker-to-mic delay plus room reverb.
    static let filterLength = 8_192

    private let state: OpaquePointer
    private let preprocessor: OpaquePointer?
    private var mic = [Int16](repeating: 0, count: frameSize)
    private var far = [Int16](repeating: 0, count: frameSize)
    private var out = [Int16](repeating: 0, count: frameSize)

    /// `suppressResidual` adds per-band residual echo suppression. SpeexDSP only applies its band gains
    /// with noise suppression on, so that runs too, limited to `noiseSuppression` dB.
    /// `echoSuppression` is the most residual echo is turned down (dB) while only the far end talks,
    /// `echoSuppressionWhileTalking` while you talk too.
    init(
        filterLength: Int = EchoCanceller.filterLength, suppressResidual: Bool = false, noiseSuppression: Int32 = -5,
        echoSuppression: Int32 = -40, echoSuppressionWhileTalking: Int32 = -15
    ) {
        state = speex_echo_state_init(Int32(Self.frameSize), Int32(filterLength))
        var rate = Int32(MonoResampler.sampleRate)
        speex_echo_ctl(state, SPEEX_ECHO_SET_SAMPLING_RATE, &rate)
        guard suppressResidual, let pre = speex_preprocess_state_init(Int32(Self.frameSize), rate) else {
            preprocessor = nil
            return
        }
        var on: Int32 = 1, off: Int32 = 0, noise = noiseSuppression
        var echo = echoSuppression, echoActive = echoSuppressionWhileTalking
        speex_preprocess_ctl(pre, SPEEX_PREPROCESS_SET_DENOISE, &on)
        speex_preprocess_ctl(pre, SPEEX_PREPROCESS_SET_NOISE_SUPPRESS, &noise)
        speex_preprocess_ctl(pre, SPEEX_PREPROCESS_SET_AGC, &off)
        speex_preprocess_ctl(pre, SPEEX_PREPROCESS_SET_VAD, &off)
        speex_preprocess_ctl(pre, SPEEX_PREPROCESS_SET_DEREVERB, &off)
        speex_preprocess_ctl(pre, SPEEX_PREPROCESS_SET_ECHO_SUPPRESS, &echo)
        speex_preprocess_ctl(pre, SPEEX_PREPROCESS_SET_ECHO_SUPPRESS_ACTIVE, &echoActive)
        speex_preprocess_ctl(pre, SPEEX_PREPROCESS_SET_ECHO_STATE, UnsafeMutableRawPointer(state))
        preprocessor = pre
    }

    deinit {
        if let preprocessor { speex_preprocess_state_destroy(preprocessor) }
        speex_echo_state_destroy(state)
    }

    /// Returns `mic` with the echo of `farEnd` removed. Both hold a multiple of `frameSize` samples
    /// covering the same moment.
    func cancel(mic micSamples: ArraySlice<Float>, farEnd farSamples: ArraySlice<Float>) -> [Float] {
        process(mic: micSamples, farEnd: farSamples).suppressed
    }

    /// Like `cancel`, but also returns the audio before residual echo suppression: a steadier signal
    /// for judging how loud the leftover echo is.
    func process(mic micSamples: ArraySlice<Float>, farEnd farSamples: ArraySlice<Float>) -> (cancelled: [Float], suppressed: [Float]) {
        precondition(micSamples.count == farSamples.count && micSamples.count % Self.frameSize == 0)
        var cancelled: [Float] = []
        var result: [Float] = []
        cancelled.reserveCapacity(micSamples.count)
        result.reserveCapacity(micSamples.count)
        for offset in stride(from: 0, to: micSamples.count, by: Self.frameSize) {
            for i in 0..<Self.frameSize {
                mic[i] = Self.int16(micSamples[micSamples.startIndex + offset + i])
                far[i] = Self.int16(farSamples[farSamples.startIndex + offset + i])
            }
            speex_echo_cancellation(state, mic, far, &out)
            cancelled += out.map { Float($0) / 32_768 }
            if let preprocessor { speex_preprocess_run(preprocessor, &out) }
            result += out.map { Float($0) / 32_768 }
        }
        return (cancelled, result)
    }

    private static func int16(_ x: Float) -> Int16 {
        Int16(max(min(x * 32_768, 32_767), -32_768))
    }
}
