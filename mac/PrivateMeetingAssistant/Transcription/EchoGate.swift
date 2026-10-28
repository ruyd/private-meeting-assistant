import Foundation

/// Keeps the other participants' voices, played through the speakers and picked up by the mic, out of
/// the "Me" transcript.
///
/// The far end is known exactly: it's the system audio tap, on the same clock as the mic. First an
/// adaptive echo canceller (SpeexDSP's MDF) subtracts the far end from the mic, which removes most of
/// the echo and leaves your voice far louder than what remains. Then the gate handles the rest. It
/// learns two things while the far end talks: the echo delay (speaker, room and device latency, found
/// by correlating the loudness of the mic with the far end's) and the echo level (how loud the mic is
/// relative to the far end at that delay, after cancellation). For every 30 ms mic frame it then predicts how loud the
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
    private static let jitterFrames = 2
    /// Mic frames wait this long (240 ms) so the far-end audio they might echo has arrived…
    private static let holdFrames = 8
    /// …or up to 1.2 s while the far end talks and the delay is still being learned, so the far end's
    /// first words are gated too (the session's first transcript lines arrive a second later).
    private static let learningHoldFrames = 40
    /// Loudness history kept for estimating the delay (6 s), and how often it's re-estimated: every
    /// 300 ms until found, so gating starts about a second into the far end's first words, then
    /// every second to follow changes (e.g. switching speakers).
    private static let historyFrames = 200
    private static let delayIntervalSearching = 10
    private static let delayInterval = 33
    private static let minDelayEvidence = 20
    /// A delay is trusted only if the loudness envelopes correlate at least this well.
    private static let minCorrelation: Float = 0.5
    /// Your voice must be 9 dB above the typical (median) echo to count as you talking: real speakers
    /// and rooms don't echo every sound equally, and a median stays put when a few unusual frames
    /// arrive, where a high percentile drifts.
    private static let nearEndMargin: Float = 8
    /// Once you're talking, keep passing audio for 300 ms so pauses inside a phrase aren't cut out.
    private static let nearEndHangover = 5
    /// Stop learning the echo level while you talk and for a second after: the quiet moments between
    /// your syllables would otherwise look like loud echo and raise the bar.
    private static let learningPause = 33
    /// Echo frames are turned down 60 dB: loud laptop-speaker echo reaches the mic at around -16 dBFS,
    /// and must end up well below the voice detector's -50 dBFS threshold, since Whisper happily
    /// transcribes even faint speech.
    private static let attenuation: Float = 0.001
    /// Far-end power below this (-60 dBFS) counts as silence.
    private static let farEndActive: Float = 1e-6
    /// Echo level samples kept (about 6 s of far-end speech: long enough that talking over the far end
    /// can't take it over, short enough to follow the canceller as it converges) and needed before
    /// gating starts.
    private static let maxRatios = 200
    private static let minRatios = 15

    private let cancelEcho: Bool
    /// Created once the delay is known: the far end is fed `cancellerDelay` frames late (a little less
    /// than the measured delay) and scaled to the echo's level, so a short filter that converges in
    /// a few seconds only has to model the room. Rebuilt if the delay moves by two frames or more.
    private var canceller: EchoCanceller?
    private var cancellerDelay = 0
    private var cancellerGain: Float = 1
    /// Far-end samples from absolute index `farBase`, for the canceller (gaps filled with silence).
    private var farSamples: [Float] = []
    private var farBase = 0
    private var farEnd: [Int: Float] = [:]
    private var farEndPartial: (frame: Int, sum: Float, count: Int)?
    private var micPower: [Int: Float] = [:]
    /// Loudness the gate judges: after cancellation when the canceller runs, else the raw mic.
    private var judgedPower: [Int: Float] = [:]
    private var mic: [Float] = []
    /// Absolute sample index of `mic[0]`.
    private var micStart: Int?
    /// Frames at the start of `mic` whose loudness is already in `micPower`.
    private var measured = 0
    /// Echo delay in frames; nil until the far end has talked enough to measure it.
    private(set) var delay: Int?
    private var framesSinceDelayEstimate = 0
    /// Debug hook: (frame, judged power, threshold or nil, gated).
    var trace: ((Int, Float, Float?, Bool) -> Void)?
    private var ratios: [Float] = []
    private var hangover = 0
    private var learningPaused = 0
    /// For diagnostics: mic frames seen, frames with far-end audio nearby, frames gated, best correlation.
    private(set) var stats = (
        frames: 0, farEndFrames: 0, gated: 0, bestCorrelation: Float(-1), bestLag: -1,
        rawEcho: Float(0), cancelledEcho: Float(0), cancellerGain: Float(0)
    )

    /// `cancelEcho` subtracts the far end before gating; off, only the gate runs (for comparison).
    init(cancelEcho: Bool = true) {
        self.cancelEcho = cancelEcho
    }

    /// Typical (median) mic power relative to far-end power at the echo delay; nil until learned.
    var echoLevel: Float? {
        guard ratios.count >= Self.minRatios else { return nil }
        return ratios.sorted()[ratios.count / 2]
    }

    /// Records far-end (system audio) samples starting at absolute sample `position`.
    mutating func addFarEnd(_ samples: [Float], at position: Int) {
        if cancelEcho {
            if farSamples.isEmpty { farBase = position }
            let end = farBase + farSamples.count
            if position > end {
                farSamples += [Float](repeating: 0, count: position - end)
            } else if position < end {
                farSamples.removeLast(min(end - position, farSamples.count))
            }
            if position >= farBase { farSamples += samples }
        }
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
        if micStart == nil {
            micStart = position
            measured = 0
        }
        mic.append(contentsOf: samples)
        guard let start = micStart else { return nil }

        // Measure loudness as audio arrives, so the delay can be learned before frames are released.
        while (measured + 1) * Self.frame <= mic.count {
            let offset = measured * Self.frame
            let index = (start + offset) / Self.frame
            var power: Float = 0
            for s in mic[offset..<(offset + Self.frame)] { power += s * s }
            micPower[index] = power / Float(Self.frame)
            measured += 1
            framesSinceDelayEstimate += 1
            if framesSinceDelayEstimate >= (delay == nil ? Self.delayIntervalSearching : Self.delayInterval) {
                framesSinceDelayEstimate = 0
                // The newest frames' far-end audio may still be on its way.
                estimateDelay(upTo: index - Self.holdFrames)
            }
        }

        let newest = (start + measured * Self.frame) / Self.frame
        let learning = delay == nil && ((newest - Self.learningHoldFrames)...newest).contains { (farEnd[$0] ?? 0) > Self.farEndActive }
        let ready = max(measured - (learning ? Self.learningHoldFrames : Self.holdFrames), 0)
        guard ready > 0 else { return nil }
        return release(frames: ready)
    }

    /// Returns the buffered mic audio (call when recording stops), gated as far as it's been measured.
    mutating func flush() -> Output? {
        defer {
            mic.removeAll()
            micStart = nil
            measured = 0
        }
        guard let start = micStart, !mic.isEmpty else { return nil }
        let rest = mic.count - measured * Self.frame
        let gated = measured > 0 ? release(frames: measured) : nil
        return Output(position: start, samples: (gated?.samples ?? []) + mic.suffix(rest))
    }

    /// Gates and removes the first `frames` measured frames of the buffer.
    private mutating func release(frames: Int) -> Output? {
        guard let start = micStart else { return nil }
        let count = frames * Self.frame
        var out = Array(mic[0..<count])
        if let canceller = prepareCanceller() {
            let lag = cancellerDelay * Self.frame
            let far = farEndSamples(from: start - lag, count: count).map { $0 * cancellerGain }
            out = canceller.cancel(mic: out[...], farEnd: far[...])
        }
        // Keep only the far end the canceller can still need.
        let drop = min(start + count - (Self.maxDelayFrames + 2) * Self.frame - farBase, farSamples.count)
        if drop > 0 {
            farSamples.removeFirst(drop)
            farBase += drop
        }
        // With the canceller, the gate judges what's left of the echo, not the raw mic.
        for offset in stride(from: 0, to: count, by: Self.frame) {
            var power: Float = 0
            for s in out[offset..<(offset + Self.frame)] { power += s * s }
            judgedPower[(start + offset) / Self.frame] = power / Float(Self.frame)
        }
        for offset in stride(from: 0, to: count, by: Self.frame) {
            let index = (start + offset) / Self.frame
            if canceller != nil, let delay, echoPeak(into: index, delay: delay) > Self.farEndActive {
                stats.rawEcho += micPower[index] ?? 0
                stats.cancelledEcho += judgedPower[index] ?? 0
                stats.cancellerGain = cancellerGain
            }
            let echo = isEcho(power: judgedPower[index] ?? 0, frame: index)
            if let trace {
                let threshold = delay.flatMap { d in echoLevel.map { Self.nearEndMargin * $0 * echoPeak(into: index, delay: d) } }
                trace(index, judgedPower[index] ?? 0, threshold, echo)
            }
            if echo {
                for i in offset..<(offset + Self.frame) { out[i] *= Self.attenuation }
            }
        }
        mic.removeFirst(count)
        micStart = start + count
        measured -= frames
        prune(before: (start + count) / Self.frame - Self.historyFrames - Self.maxDelayFrames)
        return Output(position: start, samples: out)
    }

    private mutating func isEcho(power: Float, frame index: Int) -> Bool {
        stats.frames += 1
        if hangover > 0 { hangover -= 1 }
        if learningPaused > 0 { learningPaused -= 1 }
        guard let delay else { return false }

        let farEndPeak = echoPeak(into: index, delay: delay)
        guard farEndPeak > Self.farEndActive else { return false }
        stats.farEndFrames += 1

        // Ratios are measured against the same window as the decision, so pauses between words (quiet
        // far end, room still echoing) don't inflate them. Only frames judged to be echo are added:
        // your own voice would otherwise teach the gate that echo is louder than it is.
        func learn() {
            ratios.append(power / farEndPeak)
            if ratios.count > Self.maxRatios { ratios.removeFirst() }
        }
        guard let echoLevel else {
            learn()
            return false
        }

        // You're talking if this frame and a neighbour are clearly louder than the echo could be:
        // speech is sustained, while an echo louder than usual is a single frame. (The next frame's
        // loudness is known because frames are held before release.)
        func louderThanEcho(_ f: Int) -> Bool {
            guard let p = judgedPower[f] else { return false }
            return p > Self.nearEndMargin * echoLevel * echoPeak(into: f, delay: delay)
        }
        if louderThanEcho(index) && (louderThanEcho(index - 1) || louderThanEcho(index + 1)) {
            hangover = Self.nearEndHangover
            learningPaused = Self.learningPause
            return false
        }
        guard hangover == 0 else { return false }
        // Learn only from clear echo, well under the bar: frames of your voice that land just under it
        // would otherwise raise it, gating more of your voice, which would raise it further.
        if learningPaused == 0, power < Self.nearEndMargin / 2 * echoLevel * farEndPeak { learn() }
        stats.gated += 1
        return true
    }

    /// Margin, in frames, between the measured delay and how late the canceller is fed the far end.
    private static let cancellerMargin = 2
    /// 256 ms: the margin, delay jitter and the room's reverb.
    private static let cancellerTaps = 4_096

    private mutating func prepareCanceller() -> EchoCanceller? {
        guard cancelEcho, let delay else { return nil }
        if canceller == nil || abs(delay - Self.cancellerMargin - cancellerDelay) >= 2 {
            cancellerDelay = max(delay - Self.cancellerMargin, 0)
            // Scale the far end to the echo's level (median mic-to-far power ratio at the delay).
            let ratios = micPower.compactMap { f, m -> Float? in
                guard let far = farEnd[f - delay], far > Self.farEndActive else { return nil }
                return m / far
            }.sorted()
            cancellerGain = ratios.isEmpty ? 1 : min(max(ratios[ratios.count / 2].squareRoot(), 0.125), 16)
            canceller = EchoCanceller(filterLength: Self.cancellerTaps)
        }
        return canceller
    }

    private func farEndSamples(from position: Int, count: Int) -> [Float] {
        (position..<(position + count)).map { i in
            let j = i - farBase
            return j >= 0 && j < farSamples.count ? farSamples[j] : 0
        }
    }

    /// The far end's loudest moment that can still be echoing in mic frame `index`.
    private func echoPeak(into index: Int, delay: Int) -> Float {
        let source = index - delay
        var peak: Float = 0
        for f in (source - Self.reverbFrames)...(source + Self.jitterFrames) {
            peak = max(peak, farEnd[f] ?? 0)
        }
        return peak
    }

    /// Finds the lag at which the mic's loudness envelope best follows the far end's.
    private mutating func estimateDelay(upTo index: Int) {
        let frames = (index - Self.historyFrames + 1)...index
        // Silence is clamped at the "far end active" level so quiet gaps don't dominate the correlation.
        func level(_ p: Float) -> Float { log10(max(p, Self.farEndActive)) }
        var best: (lag: Int, correlation: Float)?
        for lag in 0...Self.maxDelayFrames {
            var x: [Float] = [], y: [Float] = []
            // Frames without far-end data (before the tap started delivering) are unknown, not silent.
            for f in frames {
                guard let m = micPower[f], let far = farEnd[f - lag] else { continue }
                guard far > Self.farEndActive || m > Self.farEndActive else { continue }
                x.append(level(far))
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
                guard let m = micPower[f] else { return nil }
                let peak = echoPeak(into: f, delay: best.lag)
                return peak > Self.farEndActive ? m / peak : nil
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
        judgedPower = judgedPower.filter { $0.key >= frame }
    }
}
