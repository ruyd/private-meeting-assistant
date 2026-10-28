import AVFoundation
import OSLog
import ScreenCaptureKit

private let log = Logger(subsystem: "dev.ruy.private-meeting-assistant", category: "video")

/// Records the window of the app being recorded as an .mp4, with that app's sound and the microphone,
/// via ScreenCaptureKit. Like screenshots, it only ever captures that one window, never the rest of
/// the screen, and needs the Screen Recording permission.
@MainActor
final class WindowRecorder {
    let url: URL
    private let stream: SCStream
    private let output: SCRecordingOutput
    private let events = Events()
    private var finished: CheckedContinuation<Void, Never>?
    private var isFinished = false
    /// Set if the recording stopped by itself (the window closed, an error).
    private(set) var failure: String?
    var onStop: ((String?) -> Void)?

    /// Starts recording the app's main window into `url`. `micUID` picks the microphone (nil: the
    /// system default).
    static func start(bundleID: String, appName: String, micUID: String?, to url: URL) async throws -> WindowRecorder {
        guard ScreenCapture.hasPermission else {
            CGRequestScreenCaptureAccess()
            throw ScreenCaptureError.permission
        }
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let window = ScreenCapture.mainWindow(of: bundleID, in: content) else { throw ScreenCaptureError.noWindow(appName) }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        // Even sizes, as H.264 needs.
        config.width = max(Int(window.frame.width * scale) / 2 * 2, 2)
        config.height = max(Int(window.frame.height * scale) / 2 * 2, 2)
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.showsCursor = true
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.captureMicrophone = true
        config.microphoneCaptureDeviceID = micUID

        let recording = SCRecordingOutputConfiguration()
        recording.outputURL = url
        recording.outputFileType = .mp4
        recording.videoCodecType = .h264

        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let recorder = WindowRecorder(url: url, filter: filter, config: config, recording: recording)
        try recorder.stream.addRecordingOutput(recorder.output)
        try await recorder.stream.startCapture()
        return recorder
    }

    private init(url: URL, filter: SCContentFilter, config: SCStreamConfiguration, recording: SCRecordingOutputConfiguration) {
        self.url = url
        stream = SCStream(filter: filter, configuration: config, delegate: nil)
        output = SCRecordingOutput(configuration: recording, delegate: events)
        events.onFinish = { [weak self] error in Task { @MainActor in self?.didFinish(error) } }
    }

    /// Stops and waits until the file is complete.
    func stop() async {
        guard !isFinished else { return }
        do {
            try await stream.stopCapture()
        } catch {
            log.error("stopping video: \(error.localizedDescription, privacy: .public)")
        }
        if !isFinished {
            await withCheckedContinuation { finished = $0 }
        }
    }

    private func didFinish(_ error: String?) {
        guard !isFinished else { return }
        isFinished = true
        failure = error
        finished?.resume()
        finished = nil
        onStop?(error)
    }

    /// Receives the recording's events, which arrive off the main thread.
    private final class Events: NSObject, SCRecordingOutputDelegate, @unchecked Sendable {
        var onFinish: (@Sendable (String?) -> Void)?

        func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
            onFinish?(nil)
        }

        func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: any Error) {
            log.error("video failed: \(error.localizedDescription, privacy: .public)")
            onFinish?(error.localizedDescription)
        }
    }
}
