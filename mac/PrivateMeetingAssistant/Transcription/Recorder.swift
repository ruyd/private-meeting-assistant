import Foundation
import Observation
import Synchronization

/// A recording in progress: audio capture, live transcription and the transcript so far, saved to
/// the meeting archive line by line as it's transcribed.
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
    /// The meeting being recorded, or the one just finished.
    private(set) var meetingID: Int64?

    @ObservationIgnored private var transcriber: Transcriber?
    @ObservationIgnored private var removeEcho = true
    /// Lines handed over by the pipeline but not yet inserted (they hop to the main actor).
    @ObservationIgnored private let undelivered = DeliveryCount()
    @ObservationIgnored private var pipeline: TranscriptionPipeline?
    @ObservationIgnored private let library: MeetingLibrary
    /// Database rows of the lines on screen, so lines dropped later as echo are deleted there too.
    @ObservationIgnored private var segmentIDs: [UUID: Int64] = [:]

    init(library: MeetingLibrary = .shared) {
        self.library = library
    }

    /// `language` is an ISO code, or nil to detect it. `removeEcho` keeps the other participants'
    /// voices, heard by the mic through the speakers, out of "Me".
    func start(title: String, model: SpeechModel, language: String?, removeEcho: Bool = true) async {
        guard phase == .idle else { return }
        error = nil
        guard let store = library.store else {
            error = library.error ?? "The meeting archive isn't available."
            return
        }
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

        let started = Date()
        let meetingID: Int64
        do {
            meetingID = try store.createMeeting(title: title, startedAt: started)
        } catch {
            self.error = "Couldn't save the meeting: \(error.localizedDescription)"
            phase = .idle
            return
        }
        self.meetingID = meetingID
        lines = []
        segmentIDs = [:]
        backlog = 0
        self.removeEcho = removeEcho && capture.captureSystemAudio
        let pipeline = TranscriptionPipeline(
            transcriber: transcriber,
            language: language,
            startHostTime: mach_absolute_time(),
            removeEcho: removeEcho && capture.captureSystemAudio,
            onLine: { [undelivered] line in
                undelivered.add(1)
                Task { @MainActor [weak self] in
                    self?.insert(line)
                    undelivered.add(-1)
                }
            },
            onBacklog: { count in Task { @MainActor [weak self] in self?.backlog = count } }
        )
        await capture.start(consumer: { pipeline.append($0) })
        guard capture.state == .running else {
            await pipeline.finish()
            try? store.deleteMeeting(meetingID)
            self.meetingID = nil
            phase = .idle
            return
        }
        self.pipeline = pipeline
        library.refresh()
        startedAt = started
        phase = .recording
    }

    /// Stops capturing, then waits until everything said so far is transcribed.
    func stop() async {
        guard phase == .recording, let pipeline else { return }
        phase = .finishing
        capture.stop()
        await pipeline.finish()
        // The last lines are still hopping to the main actor; let them land before the transcript is
        // read (and, later, saved).
        while undelivered.value > 0 { await Task.yield() }
        if let meetingID { save { try $0.endMeeting(meetingID, at: Date()) } }
        library.refresh()
        self.pipeline = nil
        startedAt = nil
        phase = .idle
    }

    private func insert(_ line: TranscriptLine) {
        // Lines arrive in the order Whisper finishes them, so an echoed "Me" line may come before or
        // after the "Them" line it repeats.
        if removeEcho {
            if EchoText.isEcho(line, of: lines) { return }
            if line.source == .system {
                let withNew = lines + [line]
                for echo in lines where EchoText.isEcho(echo, of: withNew) {
                    if let id = segmentIDs.removeValue(forKey: echo.id) { save { try $0.deleteSegment(id) } }
                }
                lines.removeAll { EchoText.isEcho($0, of: withNew) }
            }
        }
        let index = lines.lastIndex { $0.startMs <= line.startMs }.map { $0 + 1 } ?? 0
        lines.insert(line, at: index)
        if let meetingID {
            save { store in
                segmentIDs[line.id] = try store.insertSegment(
                    meetingID: meetingID, source: line.source, startMs: line.startMs, endMs: line.endMs, text: line.text
                )
            }
        }
    }

    /// Writes to the archive. A failed write is shown but doesn't stop the recording.
    private func save(_ write: (MeetingStore) throws -> Void) {
        guard let store = library.store else { return }
        do {
            try write(store)
        } catch {
            self.error = "Couldn't save part of the transcript: \(error.localizedDescription)"
        }
    }
}

private final class DeliveryCount: Sendable {
    private let count = Mutex(0)
    var value: Int { count.withLock { $0 } }
    func add(_ delta: Int) { count.withLock { $0 += delta } }
}
