import Foundation
import Observation
import Synchronization

/// A recording in progress: audio capture, live transcription and the transcript so far. Each line is
/// saved to the index as it's transcribed, and the meeting's folder (transcript.md) is kept up to date.
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
    /// Screenshots taken during this recording, in order.
    private(set) var screenshots: [MeetingScreenshot] = []
    private(set) var isTakingScreenshot = false

    @ObservationIgnored private var transcriber: Transcriber?
    /// A load under way, shared by `preload` and `start` so the model is never loaded twice.
    @ObservationIgnored private var loading: (model: SpeechModel, task: Task<Transcriber, Error>)?
    @ObservationIgnored private var removeEcho = true
    /// Lines handed over by the pipeline but not yet inserted (they hop to the main actor).
    @ObservationIgnored private let undelivered = DeliveryCount()
    @ObservationIgnored private var pipeline: TranscriptionPipeline?
    @ObservationIgnored private let library: MeetingLibrary
    /// Database rows of the lines on screen, so lines dropped later as echo are deleted there too.
    @ObservationIgnored private var segmentIDs: [UUID: Int64] = [:]
    /// Pending rewrite of transcript.md; changes within two seconds are written together.
    @ObservationIgnored private var fileWrite: Task<Void, Never>?

    /// Overrides the meetings folder setting (for self-tests); nil uses the one chosen in setup.
    @ObservationIgnored private let meetingsRoot: URL?

    init(library: MeetingLibrary = .shared, meetingsRoot: URL? = nil) {
        self.library = library
        self.meetingsRoot = meetingsRoot
    }

    /// `language` is an ISO code, or nil to detect it. `removeEcho` keeps the other participants'
    /// voices, heard by the mic through the speakers, out of "Me". `details` is the calendar or Zoom
    /// meeting being recorded, if one was picked.
    func start(title: String, model: SpeechModel, language: String?, removeEcho: Bool = true, details: MeetingDetails? = nil) async {
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
        let transcriber: Transcriber
        do {
            transcriber = try await self.transcriber(for: model)
        } catch {
            self.error = "Couldn't load \(model.name): \(error.localizedDescription)"
            phase = .idle
            return
        }

        // The meeting's folder: "<title> - <date time>" in the folder chosen in setup (~/Meetings by default).
        let started = Date()
        let meetingID: Int64
        do {
            let root = meetingsRoot ?? MeetingFiles.root ?? MeetingFiles.suggestedRoot
            if meetingsRoot == nil { MeetingFiles.root = root }
            let folder = try MeetingFiles.createFolder(in: root, title: title, startedAt: started)
            meetingID = try store.createMeeting(title: title, startedAt: started, folder: folder, details: details)
        } catch {
            self.error = "Couldn't create the meeting: \(error.localizedDescription)"
            phase = .idle
            return
        }
        self.meetingID = meetingID
        library.writeFiles(meetingID)
        lines = []
        screenshots = []
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

    /// Loads the model ahead of time, so starting a recording doesn't wait for it.
    func preload(_ model: SpeechModel) async {
        guard phase == .idle, ModelStore.isComplete(model) else { return }
        _ = try? await transcriber(for: model)
    }

    /// Frees the speech model's memory (until the next `preload` or recording). Only while idle: a
    /// recording keeps its model.
    func unloadModel() {
        guard phase == .idle else { return }
        transcriber = nil
    }

    /// The loaded model, loading it (or joining a load already under way) if needed.
    private func transcriber(for model: SpeechModel) async throws -> Transcriber {
        if let transcriber, transcriber.model == model { return transcriber }
        if let loading, loading.model == model { return try await loading.task.value }
        let task = Task { try await Transcriber.load(model) }
        loading = (model, task)
        defer { if loading?.model == model { loading = nil } }
        let loaded = try await task.value
        transcriber = loaded
        return loaded
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
        if let meetingID {
            save { try $0.endMeeting(meetingID, at: Date()) }
            fileWrite?.cancel()
            library.writeFiles(meetingID)
            if !lines.isEmpty, UserDefaults.standard.object(forKey: MeetingLibrary.autoSummarizeKey) as? Bool ?? true {
                Task { [library] in await library.summarize(meetingID) }
            }
        }
        library.refresh()
        self.pipeline = nil
        startedAt = nil
        phase = .idle
    }

    /// The app being recorded, which screenshots are limited to; nil when recording all system audio or
    /// the microphone only, where there's no app to capture.
    var screenshotApp: (bundleID: String, name: String)? {
        guard capture.captureSystemAudio, let id = capture.target.bundleID else { return nil }
        return (id, capture.target.label)
    }

    /// Screenshots the app being recorded into the meeting's folder, at the current point in the transcript.
    func takeScreenshot() async {
        guard phase == .recording, !isTakingScreenshot, let app = screenshotApp, let meetingID, let startedAt,
              let folder = try? library.store?.meeting(meetingID)?.folder
        else { return }
        isTakingScreenshot = true
        defer { isTakingScreenshot = false }
        let atMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        do {
            let png = try await ScreenCapture.screenshot(of: app.bundleID, appName: app.name)
            screenshots.append(try MeetingFiles.saveScreenshot(png, at: atMs, in: folder))
            scheduleFileWrite(meetingID)
        } catch {
            self.error = "Couldn't take a screenshot: \(error.localizedDescription)"
        }
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
            scheduleFileWrite(meetingID)
        }
    }

    /// Rewrites transcript.md shortly after the transcript changes, batching lines that arrive together.
    private func scheduleFileWrite(_ meetingID: Int64) {
        guard fileWrite == nil else { return }
        fileWrite = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, !Task.isCancelled else { return }
            self.fileWrite = nil
            self.library.writeFiles(meetingID)
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
