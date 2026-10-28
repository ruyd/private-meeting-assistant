import AVFoundation
import OSLog

private let log = Logger(subsystem: "dev.ruy.private-meeting-assistant", category: "mic")

/// The default microphone via AVAudioEngine, delivered as 16 kHz mono chunks.
final class MicCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let resampler = MonoResampler()
    private let onChunk: @Sendable (AudioChunk) -> Void
    private var configObserver: NSObjectProtocol?

    init(onChunk: @escaping @Sendable (AudioChunk) -> Void) {
        self.onChunk = onChunk
    }

    static var permission: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .audio) }

    static func requestPermission() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    func start() throws {
        try installTapAndStart()
        // Fires when the input device or its format changes, e.g. a headset is plugged in.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.engine.inputNode.removeTap(onBus: 0)
            self.engine.stop()
            log.notice("mic configuration changed, restarting")
            try? self.installTapAndStart()
        }
    }

    func stop() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    private func installTapAndStart() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw CaptureError.noMicrophone }
        log.notice("mic input format: \(format.description, privacy: .public)")
        let resampler = resampler
        let onChunk = onChunk
        // The tap block runs on an AVAudioEngine worker thread (not the real-time thread),
        // so converting here is fine and keeps the resampler on a single thread.
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            guard let samples = try? resampler.convert(buffer), !samples.isEmpty else { return }
            onChunk(AudioChunk(source: .mic, samples: samples))
        }
        engine.prepare()
        try engine.start()
    }
}
