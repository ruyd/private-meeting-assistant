import AVFoundation
import OSLog
import Synchronization

private let log = Logger(subsystem: "dev.ruy.private-meeting-assistant", category: "audio-file")

/// Saves the meeting's audio, the microphone and the call mixed together, as audio.m4a in the meeting's
/// folder: 48 kHz stereo, so the call (and anything shared in it) keeps its full quality, though
/// transcription only ever hears 16 kHz. The file follows the meeting's timeline from the start, so
/// its times match the transcript: stretches where saving is turned off, or where nothing was
/// captured, are silent.
///
/// Fed from audio threads with each source at full quality (`appendFull`, placed by its capture
/// time), or with 16 kHz audio at meeting sample positions (`appendSpeech`): the mic once echo
/// removal has taken the call out of it, which only works at 16 kHz (without that, every word from
/// the call would be heard twice, the second time through the speakers and the mic). Mixed on the
/// meeting timeline and written two seconds behind, so both sources have arrived (echo removal holds
/// the mic back up to 1.2 s).
final class AudioFileRecorder: Sendable {
    static let rate = FullRateConverter.sampleRate
    private static let channels = 2
    /// 16 kHz samples to the file's: speech audio is scaled up by this much.
    private static let speechScale = Int(rate / MonoResampler.sampleRate)
    /// How far behind the newest audio the mix is written, for the other source to catch up.
    private static let latencyFrames = Int(rate * 2)
    /// A source's audio that lands within this of where its previous audio ended continues from there:
    /// timestamps drift against the sample count (the device's clock, resampling), and placing each
    /// chunk exactly by its timestamp left millisecond gaps and overlaps, heard as crackling. Further
    /// off is a real gap (system audio only flows while something plays), as transcription treats it.
    /// In 16 kHz samples, as transcription and the live recognizer count them.
    static let continuityTolerance = Int(MonoResampler.sampleRate * 0.2)
    private static let toleranceFrames = Int(rate * 0.2)

    private struct State {
        var isOn: Bool
        /// Where each source's audio so far ends, in meeting frames (48 kHz).
        var next: [AudioSource: Int] = [:]
        /// The last 16 kHz sample of each source's speech audio, to scale up smoothly across chunks.
        var lastSpeech: [AudioSource: Float] = [:]
        /// The mix not yet written (interleaved stereo), starting at meeting frame `written`.
        var mix: [Float] = []
        var written = 0
        var newest = 0
    }

    private let state: Mutex<State>
    private let startHostTime: UInt64
    /// The file is only used on `queue`, so encoding never holds up the audio threads.
    private let queue = DispatchQueue(label: "audio-file")
    private final class FileBox: @unchecked Sendable { var file: AVAudioFile? }
    private let box = FileBox()

    /// Creates the file; `isOn` is whether audio is saved from the start.
    init(url: URL, startHostTime: UInt64, isOn: Bool) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: Self.rate,
            AVNumberOfChannelsKey: Self.channels,
            AVEncoderBitRateKey: 128_000,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        self.startHostTime = startHostTime
        box.file = file
        state = Mutex(State(isOn: isOn))
    }

    var isOn: Bool { state.withLock { $0.isOn } }

    func setOn(_ on: Bool) {
        state.withLock { $0.isOn = on }
    }

    /// Called from audio threads with a captured chunk's full-quality audio, placed by its host time.
    func appendFull(_ chunk: AudioChunk) {
        guard let full = chunk.full, !full.isEmpty else { return }
        let seconds = AVAudioTime.seconds(forHostTime: chunk.hostTime) - AVAudioTime.seconds(forHostTime: startHostTime)
        append(frames: full, from: chunk.source, at: max(Int(seconds * Self.rate), 0))
    }

    /// Called from audio threads with a source's 16 kHz mono audio at (about) a meeting sample
    /// position (16 kHz): scaled up to the file's rate, the same on both sides.
    func appendSpeech(_ samples: [Float], from source: AudioSource, at position: Int) {
        guard !samples.isEmpty else { return }
        let frames = state.withLock { state -> [Float] in
            var previous = state.lastSpeech[source] ?? samples[0]
            state.lastSpeech[source] = samples[samples.count - 1]
            var out = [Float](repeating: 0, count: samples.count * Self.speechScale * Self.channels)
            for (i, s) in samples.enumerated() {
                for k in 0..<Self.speechScale {
                    // Linear steps from the previous sample to this one.
                    let v = previous + (s - previous) * Float(k + 1) / Float(Self.speechScale)
                    let frame = i * Self.speechScale + k
                    out[frame * 2] = v
                    out[frame * 2 + 1] = v
                }
                previous = s
            }
            return out
        }
        append(frames: frames, from: source, at: position * Self.speechScale)
    }

    /// Interleaved stereo frames at (about) a meeting frame position.
    private func append(frames: [Float], from source: AudioSource, at position: Int) {
        let count = frames.count / Self.channels
        let ready = state.withLock { state -> [Float]? in
            var position = position
            if let expected = state.next[source], abs(position - expected) <= Self.toleranceFrames {
                position = expected
            }
            state.next[source] = position + count
            state.newest = max(state.newest, position + count)
            if state.isOn {
                Self.add(frames, at: position, into: &state)
            }
            return Self.take(upTo: state.newest - Self.latencyFrames, from: &state)
        }
        if let ready { write(ready) }
    }

    /// Writes what's left and closes the file.
    func finish() async {
        let rest = state.withLock { state in Self.take(upTo: state.newest, from: &state) }
        if let rest { write(rest) }
        await withCheckedContinuation { continuation in
            queue.async {
                self.box.file?.close()
                self.box.file = nil
                continuation.resume()
            }
        }
    }

    /// Mixes frames in at a meeting position. Audio for a stretch already written (it arrived more
    /// than a second late) is dropped.
    private static func add(_ frames: [Float], at position: Int, into state: inout State) {
        let count = frames.count / channels
        let skip = max(state.written - position, 0)
        guard skip < count else { return }
        let offset = position + skip - state.written
        let end = (offset + count - skip) * channels
        if state.mix.count < end { state.mix.append(contentsOf: repeatElement(0, count: end - state.mix.count)) }
        for i in (skip * channels)..<frames.count {
            state.mix[offset * channels + i - skip * channels] += frames[i]
        }
    }

    /// The mix up to a meeting frame (silence where nothing was added), removed from the buffer.
    private static func take(upTo position: Int, from state: inout State) -> [Float]? {
        let count = (position - state.written) * channels
        guard count > 0 else { return nil }
        var out = Array(state.mix.prefix(count))
        if out.count < count { out.append(contentsOf: repeatElement(0, count: count - out.count)) }
        state.mix.removeFirst(min(count, state.mix.count))
        state.written = position
        // Both sources at full level can add past 1; keep within range.
        for i in out.indices { out[i] = min(max(out[i], -1), 1) }
        return out
    }

    private func write(_ interleaved: [Float]) {
        queue.async {
            let frames = interleaved.count / Self.channels
            guard let file = self.box.file,
                  let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(frames))
            else { return }
            buffer.frameLength = AVAudioFrameCount(frames)
            let left = buffer.floatChannelData![0], right = buffer.floatChannelData![1]
            for i in 0..<frames {
                left[i] = interleaved[i * 2]
                right[i] = interleaved[i * 2 + 1]
            }
            do {
                try file.write(from: buffer)
            } catch {
                log.error("couldn't write audio: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
