import AudioToolbox
import AVFoundation
import OSLog

private let log = Logger(subsystem: "dev.ruy.private-meeting-assistant", category: "mic")

/// A microphone via AVAudioEngine, delivered as 16 kHz mono chunks with rumble below voices taken
/// out (`LowCutFilter`).
final class MicCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let resampler = MonoResampler()
    private let lowCut = LowCutFilter()
    private let full = FullRateConverter()
    private let fullLowCut = LowCutFilter(sampleRate: FullRateConverter.sampleRate)
    /// nil follows the system default input.
    private let deviceUID: String?
    private let onChunk: @Sendable (AudioChunk) -> Void
    private var configObserver: NSObjectProtocol?

    init(deviceUID: String?, onChunk: @escaping @Sendable (AudioChunk) -> Void) {
        self.deviceUID = deviceUID
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
        // Falls back to the system default when the chosen device is unplugged.
        if let deviceUID, var deviceID = InputDevices.deviceID(forUID: deviceUID), let unit = input.audioUnit {
            let status = AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            if status != noErr { log.error("couldn't select input \(deviceUID, privacy: .public): \(status)") }
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw CaptureError.noMicrophone }
        log.notice("mic input format: \(format.description, privacy: .public)")
        let resampler = resampler
        let lowCut = lowCut
        let full = full
        let fullLowCut = fullLowCut
        let onChunk = onChunk
        // The tap block runs on an AVAudioEngine worker thread (not the real-time thread),
        // so converting here is fine and keeps the resampler and filter on a single thread.
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, when in
            guard let converted = try? resampler.convert(buffer), !converted.isEmpty else { return }
            let samples = lowCut.process(converted)
            // Full quality too, for the saved audio: a mic is one voice, so mono, filtered alike.
            let fullMono = full.convert(buffer).first.map { fullLowCut.process($0) }
            let hostTime = when.isHostTimeValid ? when.hostTime : mach_absolute_time()
            onChunk(AudioChunk(source: .mic, samples: samples, hostTime: hostTime, full: fullMono.flatMap { FullRateConverter.stereo([$0]) }))
        }
        engine.prepare()
        try engine.start()
    }
}
