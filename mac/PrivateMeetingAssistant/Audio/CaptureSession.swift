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
    private(set) var error: String?
    private(set) var micPermission = MicCapture.permission
    var target: SystemAudioTarget = .allExceptThisApp
    /// Off for in-person meetings: only the microphone is recorded.
    var captureSystemAudio = true

    @ObservationIgnored private let meter = LevelMeter()
    @ObservationIgnored private var mic: MicCapture?
    @ObservationIgnored private var system: SystemAudioCapture?
    @ObservationIgnored private var levelTask: Task<Void, Never>?

    /// `consumer` receives every chunk on an audio thread (mic and system chunks may arrive concurrently).
    func start(consumer: (@Sendable (AudioChunk) -> Void)? = nil) async {
        guard state == .idle else { return }
        state = .starting
        warnings = []
        error = nil
        let meter = meter
        let sink: @Sendable (AudioChunk) -> Void = { chunk in
            meter.record(chunk)
            consumer?(chunk)
        }

        if MicCapture.permission == .notDetermined { _ = await MicCapture.requestPermission() }
        micPermission = MicCapture.permission
        if micPermission == .authorized {
            let mic = MicCapture(onChunk: sink)
            do {
                try mic.start()
                self.mic = mic
            } catch {
                warnings.append("Microphone: \(error.localizedDescription)")
            }
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
        let checkMic = mic != nil
        levelTask = Task { [weak self] in
            var micChecked = !checkMic
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self else { return }
                self.levels = self.meter.take()
                // A real microphone always picks up some noise; exact zeros mean it's disconnected or blocked.
                if !micChecked, self.meter.samplesSeen(.mic) >= Int(MonoResampler.sampleRate) * 2 {
                    micChecked = true
                    if !self.meter.heardSignal(.mic) { self.warnings.append(InputDiagnostics.silentMicMessage()) }
                }
            }
        }
        state = .running
    }

    func stop() {
        levelTask?.cancel()
        levelTask = nil
        mic?.stop()
        system?.stop()
        mic = nil
        system = nil
        levels = [:]
        state = .idle
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
