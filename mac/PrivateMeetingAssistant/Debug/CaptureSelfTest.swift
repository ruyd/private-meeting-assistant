#if DEBUG
import AppKit
import AVFoundation
import OSLog
import Synchronization

private let log = Logger(subsystem: "dev.ruy.private-meeting-assistant", category: "self-test")

/// Debug builds only. Launch with `--capture-test <seconds> <output-dir> [--app <bundle-id>] [--mic <device-uid>] [--follow-suggestion] [--no-system]` to capture
/// both sources, write mic.wav, system.wav and summary.json to the folder, then quit.
/// Lets capture be checked from the command line without clicking through the UI.
enum CaptureSelfTest {
    @MainActor
    static func runIfRequested() async {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--capture-test"), args.count > i + 2,
              let seconds = Double(args[i + 1])
        else { return }
        let dir = URL(fileURLWithPath: args[i + 2], isDirectory: true)

        let micUID = args.firstIndex(of: "--mic").flatMap { args.count > $0 + 1 ? args[$0 + 1] : nil }
        let session = CaptureSession(micDeviceUID: micUID)
        if let a = args.firstIndex(of: "--app"), args.count > a + 1 {
            session.target = .app(bundleID: args[a + 1], name: args[a + 1])
        }
        session.captureSystemAudio = !args.contains("--no-system")
        log.notice("capture test: \(seconds, privacy: .public)s, mic permission \(MicCapture.permission.rawValue, privacy: .public)")
        let recorder = ChunkRecorder()
        await session.start(consumer: { recorder.append($0) })
        log.notice("capture started: state \(String(describing: session.state), privacy: .public), warnings \(session.warnings, privacy: .public), error \(session.error ?? "none", privacy: .public)")
        try? await Task.sleep(for: .seconds(seconds))
        var issue = session.micIssue.map { "\($0.message) Suggested: \($0.suggestion?.name ?? "none")" }
        // Like clicking "Use <device>": switch mics mid-capture, then check the new one is heard.
        if args.contains("--follow-suggestion"), let suggestion = session.micIssue?.suggestion {
            session.selectMic(uid: suggestion.uid)
            try? await Task.sleep(for: .seconds(3))
            issue = (issue ?? "") + " Switched; issue now: \(session.micIssue?.message ?? "none")"
        }
        session.stop()
        recorder.write(to: dir, warnings: session.warnings + [session.error, issue].compactMap { $0 })
        log.notice("capture test finished, wrote \(dir.path, privacy: .public)")
        NSApp.terminate(nil)
    }
}

private final class ChunkRecorder: Sendable {
    private let samples = Mutex<[AudioSource: [Float]]>([:])

    func append(_ chunk: AudioChunk) {
        samples.withLock { $0[chunk.source, default: []].append(contentsOf: chunk.samples) }
    }

    func write(to dir: URL, warnings: [String]) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let all = samples.withLock { $0 }
        var summary: [String: Any] = ["warnings": warnings]
        for source in AudioSource.allCases {
            let s = all[source] ?? []
            summary[source.rawValue] = [
                "seconds": Double(s.count) / MonoResampler.sampleRate,
                "rms": LevelMeter.rms(s),
                "peak": s.map(abs).max() ?? 0,
            ]
            writeWAV(s, to: dir.appending(path: "\(source.rawValue).wav"))
        }
        if let json = try? JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys]) {
            try? json.write(to: dir.appending(path: "summary.json"))
        }
    }

    private func writeWAV(_ samples: [Float], to url: URL) {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: MonoResampler.sampleRate, channels: 1, interleaved: false)!
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: MonoResampler.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
        ]
        guard !samples.isEmpty,
              let file = try? AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
        else { return }
        buffer.frameLength = buffer.frameCapacity
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        try? file.write(from: buffer)
    }
}
#endif
