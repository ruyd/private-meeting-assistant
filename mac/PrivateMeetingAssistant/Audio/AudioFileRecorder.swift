import AVFoundation
import OSLog
import Synchronization

private let log = Logger(subsystem: "dev.ruy.private-meeting-assistant", category: "audio-file")

/// Saves the meeting's audio, the microphone and the call mixed together, as audio.m4a in the meeting's
/// folder. It's fed what transcription hears, so the mic arrives with the call's echo already
/// removed (without that, every word from the call would be heard twice, the second time through
/// the speakers and the mic). The file follows the meeting's timeline from the start, so its times match the transcript:
/// stretches where saving is turned off, or where nothing was captured, are silent.
///
/// Fed from audio threads with 16 kHz audio at meeting sample positions; mixed on the meeting timeline
/// and written two seconds behind, so both sources have arrived (echo removal holds the mic back up
/// to 1.2 s).
final class AudioFileRecorder: Sendable {
    static let rate = MonoResampler.sampleRate
    /// How far behind the newest audio the mix is written, for the other source to catch up.
    private static let latencySamples = Int(rate * 2)
    /// A source's audio that lands within this of where its previous audio ended continues from there:
    /// timestamps drift against the sample count (the device's clock, resampling), and placing each
    /// chunk exactly by its timestamp left millisecond gaps and overlaps, heard as crackling. Further
    /// off is a real gap (system audio only flows while something plays), as transcription treats it.
    static let continuityTolerance = Int(rate * 0.2)

    private struct State {
        var isOn: Bool
        /// Where each source's audio so far ends, in meeting samples.
        var next: [AudioSource: Int] = [:]
        /// The mix not yet written, starting at meeting sample `written`.
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
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000,
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

    /// Called from audio threads with a captured chunk, placed by its host time.
    func append(_ chunk: AudioChunk) {
        let seconds = AVAudioTime.seconds(forHostTime: chunk.hostTime) - AVAudioTime.seconds(forHostTime: startHostTime)
        append(chunk.samples, from: chunk.source, at: max(Int(seconds * Self.rate), 0))
    }

    /// Called from audio threads with a source's audio at (about) a meeting sample position.
    func append(_ samples: [Float], from source: AudioSource, at position: Int) {
        let ready = state.withLock { state -> [Float]? in
            var position = position
            if let expected = state.next[source], abs(position - expected) <= Self.continuityTolerance {
                position = expected
            }
            state.next[source] = position + samples.count
            state.newest = max(state.newest, position + samples.count)
            if state.isOn {
                Self.add(samples, at: position, into: &state)
            }
            return Self.take(upTo: state.newest - Self.latencySamples, from: &state)
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

    /// Mixes samples in at a meeting position. Audio for a stretch already written (it arrived more
    /// than a second late) is dropped.
    private static func add(_ samples: [Float], at position: Int, into state: inout State) {
        let skip = max(state.written - position, 0)
        guard skip < samples.count else { return }
        let offset = position + skip - state.written
        let end = offset + samples.count - skip
        if state.mix.count < end { state.mix.append(contentsOf: repeatElement(0, count: end - state.mix.count)) }
        for i in skip..<samples.count {
            state.mix[offset + i - skip] += samples[i]
        }
    }

    /// The mix up to a meeting position (silence where nothing was added), removed from the buffer.
    private static func take(upTo position: Int, from state: inout State) -> [Float]? {
        let count = position - state.written
        guard count > 0 else { return nil }
        var out = Array(state.mix.prefix(count))
        if out.count < count { out.append(contentsOf: repeatElement(0, count: count - out.count)) }
        state.mix.removeFirst(min(count, state.mix.count))
        state.written = position
        // Both sources at full level can add past 1; keep within range.
        for i in out.indices { out[i] = min(max(out[i], -1), 1) }
        return out
    }

    private func write(_ samples: [Float]) {
        queue.async {
            guard let file = self.box.file,
                  let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(samples.count))
            else { return }
            buffer.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
            do {
                try file.write(from: buffer)
            } catch {
                log.error("couldn't write audio: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
