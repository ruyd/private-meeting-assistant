import Foundation
import Observation
import Synchronization

/// Captures the mic ("Me") and system audio ("Them") together and publishes live levels.
@MainActor @Observable
final class CaptureSession {
    enum State { case idle, starting, running }

    private(set) var state: State = .idle
    /// 0...1 per source, refreshed every 100 ms while running.
    private(set) var levels: [AudioSource: Float] = [:]
    /// Problems that left one source unavailable; capture continues with the other.
    private(set) var warnings: [String] = []
    /// Set when the running mic delivers only digital silence.
    private(set) var micIssue: MicIssue?
    private(set) var error: String?
    private(set) var micPermission = MicCapture.permission
    var target: SystemAudioTarget = .allExceptThisApp
    /// Off for in-person meetings: only the microphone is recorded.
    var captureSystemAudio = true
    /// The chosen input device's UID; nil follows the system default.
    private(set) var micDeviceUID: String?

    @ObservationIgnored private let meter = LevelMeter()
    @ObservationIgnored private var mic: MicCapture?
    @ObservationIgnored private var system: SystemAudioCapture?
    @ObservationIgnored private var sink: (@Sendable (AudioChunk) -> Void)?
    @ObservationIgnored private var levelTask: Task<Void, Never>?
    @ObservationIgnored private var micCheckPending = false

    init(micDeviceUID: String? = nil) {
        self.micDeviceUID = micDeviceUID
    }

    /// `consumer` receives every chunk on an audio thread (mic and system chunks may arrive concurrently).
    func start(consumer: (@Sendable (AudioChunk) -> Void)? = nil) async {
        guard state == .idle else { return }
        state = .starting
        warnings = []
        micIssue = nil
        error = nil
        let meter = meter
        meter.reset()
        let sink: @Sendable (AudioChunk) -> Void = { chunk in
            meter.record(chunk)
            consumer?(chunk)
        }
        self.sink = sink

        if MicCapture.permission == .notDetermined { _ = await MicCapture.requestPermission() }
        micPermission = MicCapture.permission
        if micPermission == .authorized {
            startMic()
        } else {
            warnings.append(CaptureError.microphoneDenied.localizedDescription)
        }

        if captureSystemAudio {
            let system = SystemAudioCapture(target: target, onChunk: sink)
            do {
                try system.start()
                self.system = system
            } catch {
                warnings.append("System audio: \(error.localizedDescription)")
            }
        }

        guard mic != nil || self.system != nil else {
            error = "Neither the microphone nor system audio could be captured."
            state = .idle
            return
        }
        levelTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self else { return }
                self.levels = self.meter.take()
                self.checkMicSignal()
            }
        }
        state = .running
    }

    /// Switches input devices, live if capture is running. nil follows the system default.
    func selectMic(uid: String?) {
        guard uid != micDeviceUID else { return }
        micDeviceUID = uid
        guard state == .running, mic != nil else { return }
        mic?.stop()
        mic = nil
        micIssue = nil
        meter.reset(.mic)
        startMic()
    }

    func stop() {
        levelTask?.cancel()
        levelTask = nil
        mic?.stop()
        system?.stop()
        mic = nil
        system = nil
        sink = nil
        levels = [:]
        state = .idle
    }

    private func startMic() {
        guard let sink else { return }
        let mic = MicCapture(deviceUID: micDeviceUID, onChunk: sink)
        do {
            try mic.start()
            self.mic = mic
            micCheckPending = true
        } catch {
            warnings.append("Microphone: \(error.localizedDescription)")
        }
    }

    /// A real microphone always picks up some noise; two seconds of exact zeros means it's
    /// disconnected (e.g. a closed MacBook lid), muted in hardware or blocked.
    private func checkMicSignal() {
        guard micCheckPending, meter.samplesSeen(.mic) >= Int(MonoResampler.sampleRate) * 2 else { return }
        micCheckPending = false
        guard !meter.heardSignal(.mic) else { return }
        let devices = InputDevices.all()
        micIssue = .silent(using: InputDevices.effective(chosenUID: micDeviceUID, among: devices), among: devices)
    }
}

/// Loudest RMS per source since the last read, shared between audio threads and the UI.
/// Also notes whether a source has delivered anything other than exact zeros.
final class LevelMeter: Sendable {
    private struct Activity {
        var samples = 0
        var heardSignal = false
    }

    private let peaks = Mutex<[AudioSource: Float]>([:])
    private let activity = Mutex<[AudioSource: Activity]>([:])

    func record(_ chunk: AudioChunk) {
        let rms = Self.rms(chunk.samples)
        peaks.withLock { $0[chunk.source] = max($0[chunk.source] ?? 0, rms) }
        activity.withLock {
            $0[chunk.source, default: Activity()].samples += chunk.samples.count
            if rms > 0 { $0[chunk.source]?.heardSignal = true }
        }
    }

    func reset(_ source: AudioSource? = nil) {
        activity.withLock { if let source { $0[source] = nil } else { $0 = [:] } }
    }

    func samplesSeen(_ source: AudioSource) -> Int { activity.withLock { $0[source]?.samples ?? 0 } }

    func heardSignal(_ source: AudioSource) -> Bool { activity.withLock { $0[source]?.heardSignal ?? false } }

    func take() -> [AudioSource: Float] {
        peaks.withLock { peaks in
            defer { peaks = [:] }
            return peaks.mapValues(Self.display)
        }
    }

    static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for s in samples { sum += s * s }
        return (sum / Float(samples.count)).squareRoot()
    }

    /// Maps RMS onto a -60…0 dBFS meter.
    static func display(_ rms: Float) -> Float {
        let db = 20 * log10(max(rms, 1e-6))
        return min(max((db + 60) / 60, 0), 1)
    }
}
