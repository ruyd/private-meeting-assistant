import AVFoundation
import OSLog
import Synchronization

private let log = Logger(subsystem: "dev.ruy.private-meeting-assistant", category: "audio-file")

/// Saves the meeting's audio, the microphone and the call mixed together, as audio.m4a in the meeting's
/// folder. The file follows the meeting's timeline from the start, so its times match the transcript:
/// stretches where saving is turned off, or where nothing was captured, are silent.
///
/// Fed from audio threads with the same 16 kHz chunks transcription gets; mixed on the meeting
/// timeline by their host time and written about a second behind, so both sources have arrived.
final class AudioFileRecorder: Sendable {
    static let rate = MonoResampler.sampleRate
    /// How far behind the newest audio the mix is written, for the other source to catch up.
    private static let latencySamples = Int(rate)

    private struct State {
        var isOn: Bool
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

    /// Called from audio threads with every captured chunk.
    func append(_ chunk: AudioChunk) {
        let seconds = AVAudioTime.seconds(forHostTime: chunk.hostTime) - AVAudioTime.seconds(forHostTime: startHostTime)
        let position = max(Int(seconds * Self.rate), 0)
        let ready = state.withLock { state -> [Float]? in
            state.newest = max(state.newest, position + chunk.samples.count)
            if state.isOn {
                Self.add(chunk.samples, at: position, into: &state)
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
