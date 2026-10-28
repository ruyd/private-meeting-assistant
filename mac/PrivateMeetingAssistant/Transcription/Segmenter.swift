/// Energy-based voice activity segmentation with an adaptive noise floor.
///
/// Cuts a continuous 16 kHz stream into utterances so each one can be sent to Whisper as soon as
/// the speaker pauses. Whisper's own no-speech probability filters out whatever non-speech noise
/// gets past this stage. Ported from the Tauri prototype (src-tauri/src/transcribe/vad.rs).
struct Segmenter {
    struct Utterance: Equatable {
        /// Offset of the first sample from the start of the stream.
        let startSample: Int
        let samples: [Float]

        var startMs: Int { startSample * 1000 / Self.rate }
        var endMs: Int { startMs + samples.count * 1000 / Self.rate }
        private static let rate = Int(MonoResampler.sampleRate)
    }

    static let frame = Int(MonoResampler.sampleRate) * 30 / 1000 // 30 ms
    private static let preRollFrames = 10 // 300 ms kept before speech onset
    private static let hangoverFrames = 23 // ~700 ms of silence ends an utterance
    private static let minSpeechFrames = 8 // drop blips shorter than ~240 ms
    private static let maxFrames = 15_000 / 30 // force a cut every 15 s
    /// Speech must be this many times louder than the noise floor (≈ +10 dB)…
    private static let floorRatio: Float = 3.2
    /// …and above this absolute level (≈ -50 dBFS).
    private static let absThreshold: Float = 0.003

    private struct Current {
        var startSample: Int
        var samples: [Float]
        var frames = 1
        var speechFrames = 1
        var silentRun = 0
    }

    private var pending: [Float] = []
    /// Absolute sample index of `pending[0]`.
    private var pendingStart = 0
    private var noiseFloor: Float = 0.001
    private var preRoll: [[Float]] = []
    private var current: Current?

    /// Absolute index of the next sample `push` expects.
    var position: Int { pendingStart + pending.count }

    mutating func push(_ samples: [Float]) -> [Utterance] {
        pending.append(contentsOf: samples)
        var out: [Utterance] = []
        var offset = 0
        while pending.count - offset >= Self.frame {
            let frame = Array(pending[offset..<(offset + Self.frame)])
            if let u = process(frame, frameStart: pendingStart + offset) { out.append(u) }
            offset += Self.frame
        }
        pending.removeFirst(offset)
        pendingStart += offset
        return out
    }

    /// Emits whatever utterance is in progress (call when recording stops).
    mutating func flush() -> Utterance? {
        guard var cur = current else { return nil }
        current = nil
        cur.samples.append(contentsOf: pending)
        pending.removeAll()
        return cur.speechFrames >= Self.minSpeechFrames ? Utterance(startSample: cur.startSample, samples: cur.samples) : nil
    }

    /// Jumps the stream forward to `sample` after a gap in delivery (system audio only flows while
    /// something plays). The gap counts as silence: any utterance in progress ends here.
    mutating func skip(to sample: Int) -> Utterance? {
        guard sample > position else { return nil }
        let ended = flush()
        pending.removeAll()
        preRoll.removeAll()
        pendingStart = sample
        return ended
    }

    private mutating func process(_ frame: [Float], frameStart: Int) -> Utterance? {
        var sum: Float = 0
        for s in frame { sum += s * s }
        let rms = (sum / Float(frame.count)).squareRoot()
        let isSpeech = rms > Self.absThreshold && rms > noiseFloor * Self.floorRatio

        // Track the floor: drop quickly to quieter levels, rise slowly so sustained speech
        // doesn't get absorbed into it.
        if !isSpeech {
            noiseFloor = max(rms < noiseFloor ? 0.7 * noiseFloor + 0.3 * rms : 0.995 * noiseFloor + 0.005 * rms, 1e-5)
        }

        guard var cur = current else {
            if isSpeech {
                let pre = preRoll.flatMap { $0 }
                preRoll.removeAll()
                current = Current(startSample: frameStart - pre.count, samples: pre + frame)
            } else {
                preRoll.append(frame)
                if preRoll.count > Self.preRollFrames { preRoll.removeFirst() }
            }
            return nil
        }

        cur.samples.append(contentsOf: frame)
        cur.frames += 1
        if isSpeech {
            cur.speechFrames += 1
            cur.silentRun = 0
        } else {
            cur.silentRun += 1
        }
        let ended = cur.silentRun >= Self.hangoverFrames
        guard ended || cur.frames >= Self.maxFrames else {
            current = cur
            return nil
        }
        current = nil
        guard cur.speechFrames >= Self.minSpeechFrames else { return nil }
        if ended {
            // Trim most of the trailing silence, keep a short tail.
            let trim = max(cur.silentRun * Self.frame - 8 * Self.frame, 0)
            cur.samples.removeLast(trim)
        }
        return Utterance(startSample: cur.startSample, samples: cur.samples)
    }
}
