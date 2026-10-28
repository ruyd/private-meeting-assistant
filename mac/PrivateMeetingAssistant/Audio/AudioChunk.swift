import AVFoundation

/// Which side of the call a chunk of audio came from.
enum AudioSource: String, Sendable, CaseIterable {
    case mic, system

    /// Speaker label used in transcripts.
    var speaker: String { self == .mic ? "Me" : "Them" }
}

/// 16 kHz mono Float32 samples from one source.
struct AudioChunk: Sendable {
    let source: AudioSource
    let samples: [Float]
}

enum CaptureError: LocalizedError {
    case noMicrophone
    case microphoneDenied
    case unsupportedFormat(String)
    case noOutputDevice
    case tapFailed(String)

    var errorDescription: String? {
        switch self {
        case .noMicrophone: "No microphone is available."
        case .microphoneDenied: "Microphone access is turned off for this app in System Settings."
        case .unsupportedFormat(let f): "Unsupported audio format: \(f)"
        case .noOutputDevice: "No audio output device is available."
        case .tapFailed(let reason): "Couldn't capture system audio: \(reason)"
        }
    }
}

/// Converts PCM buffers in any format to 16 kHz mono Float32, keeping filter state
/// between calls so a stream converts without clicks. Not thread-safe: use from one thread.
final class MonoResampler {
    static let sampleRate: Double = 16_000

    let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: MonoResampler.sampleRate, channels: 1, interleaved: false)!
    private var converter: AVAudioConverter?

    func convert(_ buffer: AVAudioPCMBuffer) throws -> [Float] {
        if converter?.inputFormat != buffer.format {
            guard let c = AVAudioConverter(from: buffer.format, to: output) else {
                throw CaptureError.unsupportedFormat(buffer.format.description)
            }
            c.downmix = true
            converter = c
        }
        guard let converter, buffer.frameLength > 0 else { return [] }

        let ratio = output.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        var samples: [Float] = []
        samples.reserveCapacity(Int(capacity))
        var fed = false
        while true {
            guard let out = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else { break }
            var error: NSError?
            let status = converter.convert(to: out, error: &error) { _, inputStatus in
                if fed {
                    // .noDataNow (not .endOfStream) keeps the resampler primed for the next buffer.
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                fed = true
                inputStatus.pointee = .haveData
                return buffer
            }
            if status == .error { throw error ?? CaptureError.unsupportedFormat(buffer.format.description) }
            if let ch = out.floatChannelData, out.frameLength > 0 {
                samples.append(contentsOf: UnsafeBufferPointer(start: ch[0], count: Int(out.frameLength)))
            }
            if status != .haveData { break }
        }
        return samples
    }
}
