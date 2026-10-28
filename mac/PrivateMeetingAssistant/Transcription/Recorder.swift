import Foundation
import Observation

/// A recording in progress: audio capture, live transcription and the transcript so far.
@MainActor @Observable
final class Recorder {
    enum Phase { case idle, loadingModel, recording, finishing }

    let capture = CaptureSession()
    private(set) var phase: Phase = .idle
    private(set) var lines: [TranscriptLine] = []
    private(set) var startedAt: Date?
    /// Utterances waiting for Whisper.
    private(set) var backlog = 0
    private(set) var error: String?

    @ObservationIgnored private var transcriber: Transcriber?
    @ObservationIgnored private var pipeline: TranscriptionPipeline?

    /// `language` is an ISO code, or nil to detect it. `removeEcho` keeps the other participants'
    /// voices, heard by the mic through the speakers, out of "Me".
    func start(model: SpeechModel, language: String?, removeEcho: Bool = true) async {
        guard phase == .idle else { return }
        error = nil
        guard ModelStore.isComplete(model) else {
            error = "Download a speech model before recording."
            return
        }
        phase = .loadingModel
        do {
            if transcriber?.model != model {
                transcriber = nil
                transcriber = try await Transcriber.load(model)
            }
        } catch {
            self.error = "Couldn't load \(model.name): \(error.localizedDescription)"
            phase = .idle
            return
        }
        guard let transcriber else { return }

        lines = []
        backlog = 0
        let pipeline = TranscriptionPipeline(
            transcriber: transcriber,
            language: language,
            startHostTime: mach_absolute_time(),
            removeEcho: removeEcho && capture.captureSystemAudio,
            onLine: { line in Task { @MainActor [weak self] in self?.insert(line) } },
            onBacklog: { count in Task { @MainActor [weak self] in self?.backlog = count } }
        )
        await capture.start(consumer: { pipeline.append($0) })
        guard capture.state == .running else {
            await pipeline.finish()
            phase = .idle
            return
        }
        self.pipeline = pipeline
        startedAt = Date()
        phase = .recording
    }

    /// Stops capturing, then waits until everything said so far is transcribed.
    func stop() async {
        guard phase == .recording, let pipeline else { return }
        phase = .finishing
        capture.stop()
        await pipeline.finish()
        self.pipeline = nil
        startedAt = nil
        phase = .idle
    }

    private func insert(_ line: TranscriptLine) {
        let index = lines.lastIndex { $0.startMs <= line.startMs }.map { $0 + 1 } ?? 0
        lines.insert(line, at: index)
    }
}
