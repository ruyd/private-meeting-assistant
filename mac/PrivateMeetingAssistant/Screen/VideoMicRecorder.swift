import AVFoundation
import Synchronization

/// The echo-removed microphone while a video records ("Record video + mic"), kept in a temporary
/// file to be mixed into the video when it stops (`VideoSoundMixer`). 16 kHz mono, continuous from
/// the first audio on: small timestamp jitter continues where the last chunk ended (as in
/// `AudioFileRecorder`), and real gaps are filled with silence.
final class VideoMicRecorder: Sendable {
    let url: URL
    private struct State {
        /// Meeting position of the file's first sample, and where the audio so far ends.
        var first: Int?
        var next = 0
        var isFinished = false
    }
    private let state = Mutex(State())
    /// The file is only used on `queue`, so writing never holds up the audio threads.
    private let queue = DispatchQueue(label: "video-mic")
    private final class FileBox: @unchecked Sendable { var file: AVAudioFile? }
    private let box = FileBox()
    private let format = AVAudioFormat(standardFormatWithSampleRate: MonoResampler.sampleRate, channels: 1)!

    init() throws {
        url = FileManager.default.temporaryDirectory.appending(path: "video-mic-\(UUID().uuidString).caf")
        box.file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    /// Called from the transcription pipeline's audio callback with echo-removed mic audio.
    func append(_ samples: [Float], at position: Int) {
        let toWrite: [Float]? = state.withLock { state in
            guard !state.isFinished else { return nil }
            guard state.first != nil else {
                state.first = position
                state.next = position + samples.count
                return samples
            }
            var position = position
            if abs(position - state.next) <= AudioFileRecorder.continuityTolerance { position = state.next }
            if position < state.next {
                // Overlaps what's written: keep only the new part.
                let skip = state.next - position
                guard skip < samples.count else { return nil }
                state.next += samples.count - skip
                return Array(samples[skip...])
            }
            let gap = position - state.next
            state.next = position + samples.count
            return [Float](repeating: 0, count: gap) + samples
        }
        guard let toWrite, !toWrite.isEmpty, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(toWrite.count)) else { return }
        buffer.frameLength = AVAudioFrameCount(toWrite.count)
        toWrite.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: toWrite.count) }
        let box = box
        queue.async { try? box.file?.write(from: buffer) }
    }

    /// Stops taking audio and closes the file. Returns the meeting position of its first sample (nil
    /// if no audio came).
    func finish() -> Int? {
        let first = state.withLock { state in
            state.isFinished = true
            return state.first
        }
        let box = box
        queue.sync { box.file = nil }
        return first
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}
