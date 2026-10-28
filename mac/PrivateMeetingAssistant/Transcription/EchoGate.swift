import Foundation

/// Keeps the other participants' voices, played through the speakers and picked up by the mic, out of
/// the "Me" transcript.
///
/// The far end is known exactly: it's the system audio tap, on the same clock as the mic. The gate
/// learns two things while the far end talks: the echo delay (speaker, room and device latency, found
/// by correlating the loudness of the mic with the far end's) and the echo level (how loud the mic is
/// relative to the far end at that delay). For every 30 ms mic frame it then predicts how loud the
/// echo is; frames no louder than that are attenuated before voice detection, so they never become
/// "Me" utterances. When you talk, the mic is clearly louder than the predicted echo and passes
/// through untouched, including when you talk over the other side.
///
/// Apple's voice processing can't be used instead: it only cancels audio played through its own
/// output, and enabling it silenced both the mic and the process tap in testing.
struct EchoGate {
    struct Output: Equatable {
        /// Absolute sample index of the first sample.
        let position: Int
        let samples: [Float]
    }

    static let frame = Segmenter.frame
    /// Echo delays considered: up to 450 ms after the tap sees the far-end audio.
    private static let maxDelayFrames = 15
    /// Frames before and after the delay that can still be echo (jitter and room reverb).
    private static let reverbFrames = 5
    private static let jitterFrames = 1
    /// Mic frames wait this long (240 ms) so the far-end audio they might echo has arrived.
    private static let holdFrames = 8
    /// Loudness history kept for estimating the delay (6 s), and how often it's re-estimated: every
    /// 300 ms until found, so gating starts about a second into the far end's first words, then
    /// every second to follow changes (e.g. switching speakers).
    private static let historyFrames = 200
    private static let delayIntervalSearching = 10
    private static let delayInterval = 33
    private static let minDelayEvidence = 20
    /// A delay is trusted only if the loudness envelopes correlate at least this well.
    private static let minCorrelation: Float = 0.5
    /// Your voice must be 6 dB above the predicted echo to count as you talking.
    private static let nearEndMargin: Float = 4
    /// Once you're talking, keep passing audio for 150 ms so word endings aren't clipped.
    private static let nearEndHangover = 5
    /// Echo frames are turned down 60 dB: loud laptop-speaker echo reaches the mic at around -16 dBFS,
    /// and must end up well below the voice detector's -50 dBFS threshold, since Whisper happily
    /// transcribes even faint speech.
    private static let attenuation: Float = 0.001
    /// Far-end power below this (-60 dBFS) counts as silence.
    private static let farEndActive: Float = 1e-6
    /// Echo level samples kept (about 10 s of far-end speech) and needed before gating starts.
    private static let maxRatios = 330
    private static let minRatios = 15

    private var farEnd: [Int: Float] = [:]
    private var farEndPartial: (frame: Int, sum: Float, count: Int)?
    private var micPower: [Int: Float] = [:]
    private var mic: [Float] = []
    /// Absolute sample index of `mic[0]`.
    private var micStart: Int?
    /// Echo delay in frames; nil until the far end has talked enough to measure it.
    private(set) var delay: Int?
    private var framesSinceDelayEstimate = 0
    private var ratios: [Float] = []
    private var hangover = 0
    /// For diagnostics: mic frames seen, frames with far-end audio nearby, frames gated, best correlation.
    private(set) var stats = (frames: 0, farEndFrames: 0, gated: 0, bestCorrelation: Float(-1), bestLag: -1)

    /// Mic power relative to far-end power at the echo delay; nil until learned.
    var echoLevel: Float? {
        guard ratios.count >= Self.minRatios else { return nil }
        // Median: echo-only frames dominate while the far end talks; double talk only raises a minority.
        return ratios.sorted()[ratios.count / 2]
    }

    /// Records far-end (system audio) samples starting at absolute sample `position`.
    mutating func addFarEnd(_ samples: [Float], at position: Int) {
        for (i, s) in samples.enumerated() {
            let frame = (position + i) / Self.frame
            if let partial = farEndPartial, partial.frame != frame {
                farEnd[partial.frame] = partial.sum / Float(partial.count)
                farEndPartial = nil
            }
            var partial = farEndPartial ?? (frame, 0, 0)
            partial.sum += s * s
            partial.count += 1
            farEndPartial = partial
        }
    }

    /// Takes mic samples starting at absolute sample `position` and returns gated audio that's ready,
    /// about 240 ms behind the input.
    mutating func processMic(_ samples: [Float], at position: Int) -> Output? {
        if let start = micStart, position > start + mic.count + Self.frame * 7 {
            // The mic stream jumped (device change): pass what's buffered and restart there.
            let flushed = flush()
            micStart = position
            mic = samples
            return flushed
        }
        if micStart == nil { micStart = position }
        mic.append(contentsOf: samples)

        guard let start = micStart else { return nil }
        let ready = max(mic.count / Self.frame - Self.holdFrames, 0) * Self.frame
        guard ready > 0 else { return nil }
        var out = Array(mic[0..<ready])
        for offset in stride(from: 0, to: ready, by: Self.frame) {
            if isEcho(out[offset..<(offset + Self.frame)], frame: (start + offset) / Self.frame) {
                for i in offset..<(offset + Self.frame) { out[i] *= Self.attenuation }
            }
        }
        mic.removeFirst(ready)
        micStart = start + ready
        prune(before: (start + ready) / Self.frame - Self.historyFrames - Self.maxDelayFrames)
        return Output(position: start, samples: out)
    }

    /// Returns the buffered mic audio ungated (call when recording stops).
    mutating func flush() -> Output? {
        defer {
            mic.removeAll()
            micStart = nil
        }
        guard let start = micStart, !mic.isEmpty else { return nil }
        return Output(position: start, samples: mic)
    }

    private mutating func isEcho(_ frame: ArraySlice<Float>, frame index: Int) -> Bool {
        var power: Float = 0
        for s in frame { power += s * s }
        power /= Float(frame.count)
        micPower[index] = power
        stats.frames += 1

        framesSinceDelayEstimate += 1
        if framesSinceDelayEstimate >= (delay == nil ? Self.delayIntervalSearching : Self.delayInterval) {
            framesSinceDelayEstimate = 0
            estimateDelay(upTo: index)
        }
        if hangover > 0 { hangover -= 1 }
        guard let delay else { return false }

        // The far end's loudest moment that can still be echoing in this frame.
        let source = index - delay
        var farEndPeak: Float = 0
        for f in (source - Self.reverbFrames)...(source + Self.jitterFrames) {
            farEndPeak = max(farEndPeak, farEnd[f] ?? 0)
        }
        guard farEndPeak > Self.farEndActive else { return false }
        stats.farEndFrames += 1

        if let direct = farEnd[source], direct > Self.farEndActive {
            ratios.append(power / direct)
            if ratios.count > Self.maxRatios { ratios.removeFirst() }
        }
        guard let echoLevel else { return false }
        if power > Self.nearEndMargin * echoLevel * farEndPeak {
            hangover = Self.nearEndHangover
            return false
        }
        if hangover == 0 { stats.gated += 1 }
        return hangover == 0
    }

    /// Finds the lag at which the mic's loudness envelope best follows the far end's.
    private mutating func estimateDelay(upTo index: Int) {
        let frames = (index - Self.historyFrames + 1)...index
        func level(_ p: Float?) -> Float { log10(max(p ?? 0, 1e-9)) }
        var best: (lag: Int, correlation: Float)?
        for lag in 0...Self.maxDelayFrames {
            var x: [Float] = [], y: [Float] = []
            for f in frames where (farEnd[f - lag] ?? 0) > Self.farEndActive || (micPower[f] ?? 0) > Self.farEndActive {
                guard let m = micPower[f] else { continue }
                x.append(level(farEnd[f - lag]))
                y.append(level(m))
            }
            guard x.count >= Self.minDelayEvidence, let c = Self.correlation(x, y) else { continue }
            if c > (best?.correlation ?? -1) { best = (lag, c) }
        }
        if let best, best.correlation > stats.bestCorrelation { stats.bestCorrelation = best.correlation; stats.bestLag = best.lag }
        if let best, best.correlation >= Self.minCorrelation, best.lag != delay {
            delay = best.lag
            // Levels measured at the old delay don't apply; measure them from the history at the new one
            // so gating starts now rather than after another half second of far-end speech.
            ratios = frames.compactMap { f in
                guard let m = micPower[f], let far = farEnd[f - best.lag], far > Self.farEndActive else { return nil }
                return m / far
            }.suffix(Self.maxRatios)
        }
    }

    private static func correlation(_ x: [Float], _ y: [Float]) -> Float? {
        let n = Float(x.count)
        let mx = x.reduce(0, +) / n, my = y.reduce(0, +) / n
        var sxy: Float = 0, sxx: Float = 0, syy: Float = 0
        for (a, b) in zip(x, y) {
            sxy += (a - mx) * (b - my)
            sxx += (a - mx) * (a - mx)
            syy += (b - my) * (b - my)
        }
        guard sxx > 0, syy > 0 else { return nil }
        return sxy / (sxx * syy).squareRoot()
    }

    private mutating func prune(before frame: Int) {
        guard micPower.count > Self.historyFrames * 2 else { return }
        farEnd = farEnd.filter { $0.key >= frame }
        micPower = micPower.filter { $0.key >= frame }
    }
}
