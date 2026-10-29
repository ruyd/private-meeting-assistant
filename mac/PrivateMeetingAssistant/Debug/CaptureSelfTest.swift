#if DEBUG
import AppKit
import AVFoundation
import OSLog
import Synchronization

private let log = Logger(subsystem: "dev.ruy.private-meeting-assistant", category: "self-test")

/// Debug builds only. Launch with `--capture-test <seconds> <output-dir> [--app <bundle-id>] [--mic <device-uid>] [--follow-suggestion] [--no-system]` to capture
/// both sources, write mic.wav, system.wav and summary.json to the folder, then quit.
/// Lets capture be checked from the command line without clicking through the UI.
/// `--prepare-model <variant>` downloads and loads a speech model instead.
enum CaptureSelfTest {
    @MainActor
    static func runIfRequested() async {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--prepare-model"), args.count > i + 1, let model = SpeechModel.find(args[i + 1]) {
            await prepare(model)
            NSApp.terminate(nil)
            return
        }
        if args.contains("--install-ollama") {
            // Downloads, verifies and starts the app's own Ollama, then stops it.
            let engine = SummaryEngine.shared
            await engine.installOllama()
            var version = "-"
            if engine.isDownloadedInstalled {
                do {
                    try await engine.startServer()
                    version = try await SummaryEngine.version(at: SummaryEngine.downloadedURL)
                } catch {
                    version = "start failed: \(error.localizedDescription)"
                }
                engine.stopServer()
            }
            log.notice("install-ollama: installed \(engine.isDownloadedInstalled), version \(version, privacy: .public), error \(engine.error ?? "none", privacy: .public)")
            NSApp.terminate(nil)
            return
        }
        if let i = args.firstIndex(of: "--transcribe-test"), args.count > i + 2, let seconds = Double(args[i + 1]) {
            await transcribe(seconds: seconds, to: URL(fileURLWithPath: args[i + 2], isDirectory: true), args: args)
            NSApp.terminate(nil)
            return
        }
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

extension CaptureSelfTest {
    /// `--prepare-model <id>`: downloads the model if needed (with the free-space check), then loads it
    /// once to check it works. Logs how long each step took.
    @MainActor
    static func prepare(_ model: SpeechModel) async {
        let store = ModelStore.shared
        var clock = ContinuousClock.now
        if !ModelStore.isComplete(model) {
            store.download(model)
            await store.waitForDownload(model)
            log.notice("download \(model.id, privacy: .public): \(ModelStore.isComplete(model) ? "complete" : "FAILED", privacy: .public) in \(ContinuousClock.now - clock, privacy: .public); error: \(store.error ?? "none", privacy: .public)")
        }
        guard ModelStore.isComplete(model) else { return }
        clock = .now
        do {
            _ = try await Transcriber.load(model)
            log.notice("load \(model.id, privacy: .public): ok in \(ContinuousClock.now - clock, privacy: .public)")
        } catch {
            log.notice("load \(model.id, privacy: .public): FAILED \(error.localizedDescription, privacy: .public)")
        }
    }
}

extension CaptureSelfTest {
    /// `--transcribe-test <seconds> <output-dir> [--model <id>] [--app <bundle-id>] [--keep-echo]
    /// [--video | --video-mic] [--cut] [--muted]`: records with live transcription and writes transcript.json (lines in
    /// order, with timing). `--video` records the app's window from 2 s in until 2 s before the end
    /// (`--video-mic` with your voice mixed in, `--cut` cut down to the video in it), into the output
    /// folder's Meetings. `--muted` starts with the microphone muted.
    @MainActor
    static func transcribe(seconds: Double, to dir: URL, args: [String]) async {
        let modelID = args.firstIndex(of: "--model").flatMap { args.count > $0 + 1 ? args[$0 + 1] : nil }
        let model = modelID.flatMap(SpeechModel.find) ?? .recommended
        // Saves to its own database in the output folder, never the real archive.
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try? MeetingStore.open(at: dir.appending(path: "meetings.sqlite"))
        let recorder = Recorder(library: MeetingLibrary(store: store), meetingsRoot: dir.appending(path: "Meetings"))
        if let a = args.firstIndex(of: "--app"), args.count > a + 1 {
            recorder.capture.target = .app(bundleID: args[a + 1], name: args[a + 1])
        }
        recorder.isMicMuted = args.contains("--muted")
        let clock = ContinuousClock.now
        await recorder.start(title: "Self-test", model: model, language: "en", removeEcho: !args.contains("--keep-echo"))
        log.notice("transcribe test: started in \(ContinuousClock.now - clock, privacy: .public), phase \(String(describing: recorder.phase), privacy: .public), error \(recorder.error ?? "none", privacy: .public)")
        if args.contains("--video") || args.contains("--video-mic"), seconds > 5 {
            try? await Task.sleep(for: .seconds(2))
            await recorder.toggleVideo(withMic: args.contains("--video-mic"), cutSize: args.contains("--cut"))
            log.notice("transcribe test: video \(recorder.isRecordingVideo ? "recording" : "didn't start: \(recorder.error ?? "")", privacy: .public)")
            try? await Task.sleep(for: .seconds(seconds - 4))
            await recorder.toggleVideo()
            try? await Task.sleep(for: .seconds(2))
        } else {
            try? await Task.sleep(for: .seconds(seconds))
        }
        let stopClock = ContinuousClock.now
        await recorder.stop()
        let lines = recorder.lines.map {
            ["speaker": $0.source.speaker, "startMs": $0.startMs, "endMs": $0.endMs, "text": $0.text] as [String: Any]
        }
        // Recording stopped; with auto-summarize on, a summary is being written. Wait for it.
        var summaryStatus = "none"
        var summaryText: String?
        // Nothing said: no summary is written, so there's nothing to wait for.
        if let id = recorder.meetingID, !lines.isEmpty {
            for _ in 0..<600 {
                summaryStatus = (try? store?.meeting(id))??.summaryStatus ?? "none"
                if summaryStatus != "running" && summaryStatus != "none" { break }
                try? await Task.sleep(for: .milliseconds(500))
            }
            summaryText = (try? store?.meeting(id))??.summary?.summary
        }
        let saved = recorder.meetingID.flatMap { try? store?.segments(of: $0) } ?? []
        let summary: [String: Any] = [
            "model": model.id,
            "savedLines": saved.count,
            "summaryStatus": summaryStatus,
            "summary": summaryText ?? NSNull(),
            "savedMatchesScreen": saved.map(\.text) == recorder.lines.map(\.text),
            "finishSeconds": Double((ContinuousClock.now - stopClock).components.seconds),
            "lines": lines,
            "warnings": recorder.capture.warnings,
        ]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let json = try? JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys]) {
            try? json.write(to: dir.appending(path: "transcript.json"))
        }
    }
}

/// Keeps each source on the meeting timeline, like the transcription pipeline does: gaps in delivery
/// (system audio pauses while nothing plays) are filled with silence, so the WAVs line up.
private final class ChunkRecorder: Sendable {
    private let samples = Mutex<[AudioSource: [Float]]>([:])
    private let startHostTime = mach_absolute_time()

    func append(_ chunk: AudioChunk) {
        let seconds = AVAudioTime.seconds(forHostTime: chunk.hostTime) - AVAudioTime.seconds(forHostTime: startHostTime)
        let position = max(Int(seconds * MonoResampler.sampleRate), 0)
        samples.withLock {
            var track = $0[chunk.source] ?? []
            if position > track.count + Int(MonoResampler.sampleRate * 0.2) {
                track += [Float](repeating: 0, count: position - track.count)
            }
            track += chunk.samples
            $0[chunk.source] = track
        }
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
