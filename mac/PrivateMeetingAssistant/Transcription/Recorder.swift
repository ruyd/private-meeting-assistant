import Foundation
import Observation
import Synchronization
import OSLog
import ScreenCaptureKit

private let liveLog = Logger(subsystem: "dev.ruy.private-meeting-assistant", category: "live-transcript")

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
    /// Whether this recording tells voices apart (Participant 1, 2…) instead of one "Them".
    private(set) var identifiesSpeakers = false
    /// Whether the meeting's audio is being saved to audio.m4a.
    private(set) var isSavingAudio = false
    /// The window recording in progress, and videos recorded so far (by when each started).
    private(set) var isRecordingVideo = false
    private(set) var isStartingVideo = false
    private(set) var videos: [MeetingScreenshot] = []
    @ObservationIgnored private var windowRecorder: WindowRecorder?
    /// The echo-removed mic while a "Record video + mic" video records.
    @ObservationIgnored private let videoMic = VideoMicBox()
    /// Videos being finished (mic mixed in, cut down), which stopping waits for.
    @ObservationIgnored private var videoMixes: [Task<Void, Never>] = []
    /// Whether the microphone is muted: its audio is replaced with silence before anything hears it
    /// (transcript, live text, saved audio, a video's mic), keeping the timeline whole. Set before
    /// starting to begin muted.
    var isMicMuted = false {
        didSet {
            micMuted.set(isMicMuted)
            guard phase == .recording, isMicMuted != oldValue else { return }
            if isMicMuted {
                mutedSpans.append(MutedSpan(startMs: elapsedMs))
            } else if !mutedSpans.isEmpty {
                mutedSpans[mutedSpans.count - 1].endMs = elapsedMs
            }
        }
    }
    @ObservationIgnored private let micMuted = Flag()
    /// When the mic was muted, in meeting milliseconds. Speech from just before muting is
    /// transcribed a little later and its line can be timed into the muted stretch: a "Me" line
    /// centred in one is dropped.
    @ObservationIgnored private var mutedSpans: [MutedSpan] = []

    /// Videos being finished (mic mixed in, cut down), shown as such in the transcript.
    private(set) var finishingVideos: Set<URL> = []
    var isMixingVideo: Bool { !finishingVideos.isEmpty }
    /// The recorded app's windows, while asking which one to capture (none: not asking).
    private(set) var windowChoices: [CaptureWindowChoice] = []
    /// What to capture once its window is chosen.
    @ObservationIgnored private var pendingCapture: PendingCapture?
    private enum PendingCapture {
        case video(withMic: Bool, cutSize: Bool)
        case screenshot(atMs: Int)
    }
    /// The window chosen for this recording's screenshots and videos, used again while it's open.
    @ObservationIgnored private var chosenWindow: CGWindowID?
    /// The audio file, once saving audio was first turned on; the capture threads write to it.
    @ObservationIgnored private let audioFile = AudioFileBox()
    /// Words as they're spoken, per source, until Whisper's line for that stretch arrives
    /// (`LiveTranscriber`); empty while showing live text is off.
    private(set) var liveText: [AudioSource: String] = [:]
    /// Whether live text is shown (the live view's Live / Delayed switch).
    private(set) var showsLiveText = false
    @ObservationIgnored private let live = LiveTranscriberBox()
    @ObservationIgnored private var liveFragments: [AudioSource: (finals: [LiveTranscriber.Fragment], volatile: LiveTranscriber.Fragment?)] = [:]
    /// How far Whisper's lines reach on each source, in meeting milliseconds: live text up to here is
    /// replaced by them.
    @ObservationIgnored private var whisperReachMs: [AudioSource: Int] = [:]
    /// Where the live recognizer found words, per source, to catch lines Whisper made up.
    @ObservationIgnored private var heard: [AudioSource: LiveTranscriber.Heard] = [:]
    @ObservationIgnored private var liveLocale = Locale.current
    @ObservationIgnored private var startHostTime: UInt64 = 0

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
    /// meeting being recorded, if one was picked. `identifySpeakers` tells the voices apart: those
    /// heard through the computer when recording system audio (the microphone stays "Me"), or
    /// everyone in the room when recording the microphone only.
    func start(
        title: String, model: SpeechModel, language: String?, removeEcho: Bool = true,
        details: MeetingDetails? = nil, identifySpeakers: Bool = false, saveAudio: Bool = false
    ) async {
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
        videos = []
        chosenWindow = nil
        segmentIDs = [:]
        backlog = 0
        self.removeEcho = removeEcho && capture.captureSystemAudio
        let voiceprinter = identifySpeakers ? Voiceprinter.load() : nil
        identifiesSpeakers = voiceprinter != nil
        startHostTime = mach_absolute_time()
        heard = [:]
        mutedSpans = isMicMuted ? [MutedSpan(startMs: 0)] : []
        audioFile.set(nil)
        let pipeline = TranscriptionPipeline(
            transcriber: transcriber,
            language: language,
            startHostTime: startHostTime,
            removeEcho: removeEcho && capture.captureSystemAudio,
            voiceprinter: voiceprinter,
            identifySpeakers: capture.captureSystemAudio ? [.system] : [.mic],
            // The saved audio gets the mic after echo removal, like the transcript.
            onAudio: { [audioFile, live, videoMic] source, samples, position in
                audioFile.append(samples, from: source, at: position)
                live.append(samples, from: source, at: position)
                if source == .mic { videoMic.append(samples, at: position) }
            },
            onLine: { [undelivered] line in
                undelivered.add(1)
                Task { @MainActor [weak self] in
                    self?.insert(line)
                    undelivered.add(-1)
                }
            },
            onBacklog: { count in Task { @MainActor [weak self] in self?.backlog = count } }
        )
        await capture.start(consumer: { [micMuted] chunk in
            pipeline.append(chunk.source == .mic && micMuted.isOn
                ? AudioChunk(source: .mic, samples: [Float](repeating: 0, count: chunk.samples.count), hostTime: chunk.hostTime)
                : chunk)
        })
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
        if saveAudio { setSavingAudio(true) }
        liveLocale = language.map { Locale(identifier: $0) } ?? Locale.current
        // In the background: the recognizer's language model may still be downloading the first time.
        Task { await setLiveText(UserDefaults.standard.object(forKey: SettingsKeys.liveTranscript) as? Bool ?? true) }
    }

    // MARK: Live text

    /// Shows words as they're spoken (Apple's on-device recognizer, per source) or only Whisper's
    /// lines. Remembered for the next recording.
    func setLiveText(_ on: Bool) async {
        UserDefaults.standard.set(on, forKey: SettingsKeys.liveTranscript)
        showsLiveText = on
        guard phase == .recording || phase == .loadingModel else { return }
        if !on {
            stopHearing()
            await live.stopAll()
            liveFragments = [:]
            liveText = [:]
            return
        }
        let sources: [AudioSource] = capture.captureSystemAudio ? [.mic, .system] : [.mic]
        for source in sources where !live.has(source) {
            liveLog.notice("starting live text for \(source.rawValue, privacy: .public)")
            live.expect(source)
            let transcriber = await LiveTranscriber.start(locale: liveLocale) { [weak self] fragment in
                Task { @MainActor in self?.receive(fragment, from: source) }
            }
            // Turned off, or the recording stopped, while the recognizer was starting.
            guard showsLiveText, phase == .recording, let transcriber else {
                live.cancel(source)
                await transcriber?.stop()
                continue
            }
            let from = live.set(transcriber, for: source).map { $0 * 1000 / Int(MonoResampler.sampleRate) }
            heard[source] = LiveTranscriber.Heard(from: from ?? elapsedMs)
        }
    }

    /// Milliseconds since the recording started.
    private var elapsedMs: Int {
        Int(Double(mach_absolute_time() - startHostTime) * Self.hostTicksPerMs)
    }

    private static let hostTicksPerMs: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1_000_000
    }()

    /// Marks where the live recognizers stop listening.
    private func stopHearing() {
        let now = elapsedMs
        for source in heard.keys where heard[source]?.until == nil { heard[source]?.until = now }
    }

    private func receive(_ fragment: LiveTranscriber.Fragment, from source: AudioSource) {
        if liveFragments[source] == nil { liveLog.notice("first live text from \(source.rawValue, privacy: .public)") }
        heard[source]?.add(fragment)
        // Silence comes back as a lone "." now and then (a muted mic, a quiet room): not words.
        guard fragment.text.contains(where: { $0.isLetter || $0.isNumber }) else { return }
        // Muted: nothing from the mic shows.
        if source == .mic, isMicMuted { return }
        guard showsLiveText else { return }
        var f = liveFragments[source] ?? ([], nil)
        if fragment.isFinal {
            f.finals.append(fragment)
            f.volatile = nil
        } else {
            f.volatile = fragment
        }
        liveFragments[source] = f
        updateLiveText(source)
    }

    /// The live text not yet covered by Whisper's lines on that source: a fragment goes once Whisper
    /// reaches past its middle. (Apple's fragments can span several of Whisper's lines and end a little
    /// after them, so waiting for Whisper to pass their end left stale text showing.)
    private func updateLiveText(_ source: AudioSource) {
        guard var f = liveFragments[source] else { return }
        let reach = whisperReachMs[source] ?? -1
        f.finals.removeAll { $0.isCovered(byWhisperReaching: reach) }
        if f.volatile?.isCovered(byWhisperReaching: reach) == true { f.volatile = nil }
        liveFragments[source] = f
        let text = (f.finals.map(\.text) + [f.volatile?.text].compactMap { $0 }).joined(separator: " ")
        liveText[source] = text.isEmpty ? nil : text
    }

    // MARK: Audio and video

    /// Turns saving the meeting's audio (audio.m4a) on or off. The file covers the whole meeting, so
    /// stretches with saving off are silent and times match the transcript.
    func setSavingAudio(_ on: Bool) {
        guard phase == .recording, let meetingID, let folder = try? library.store?.meeting(meetingID)?.folder else { return }
        if on, audioFile.recorder == nil {
            do {
                audioFile.set(try AudioFileRecorder(
                    url: folder.appending(path: MeetingFiles.audioFile), startHostTime: startHostTime, isOn: true
                ))
                scheduleFileWrite(meetingID)
            } catch {
                self.error = "Couldn't save the audio: \(error.localizedDescription)"
                return
            }
        }
        audioFile.recorder?.setOn(on)
        isSavingAudio = on
    }

    /// Whether a video can be recorded: only of an app's window (not all system audio or the
    /// microphone only), like screenshots.
    var canRecordVideo: Bool { screenshotApp != nil }

    /// Starts recording the app's window as video, with your (echo-removed) voice mixed in when
    /// `withMic` and cut down (full width, without the browser's tabs and the page below the
    /// video) and smaller when `cutSize`, or stops the recording in progress. Which window: see
    /// `captureWindow`.
    func toggleVideo(withMic: Bool = false, cutSize: Bool = false) async {
        if let windowRecorder {
            await windowRecorder.stop()
            return
        }
        guard phase == .recording, !isStartingVideo, windowChoices.isEmpty, let app = screenshotApp else { return }
        isStartingVideo = true
        defer { isStartingVideo = false }
        do {
            guard let window = try await captureWindow(of: app, else: .video(withMic: withMic, cutSize: cutSize)) else { return }
            try await startVideo(in: window, withMic: withMic, cutSize: cutSize)
        } catch {
            self.error = "Couldn't record video: \(error.localizedDescription)"
        }
    }

    /// Captures what was asked for in the window picked from `windowChoices` (nil: cancelled), and
    /// keeps using that window for this recording.
    func chooseWindow(_ id: CGWindowID?) async {
        let pending = pendingCapture
        pendingCapture = nil
        windowChoices = []
        guard let id, let pending, phase == .recording else { return }
        chosenWindow = id
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            guard let window = content.windows.first(where: { $0.windowID == id }) else {
                throw ScreenCaptureError.noWindow(screenshotApp?.name ?? "the app")
            }
            switch pending {
            case .video(let withMic, let cutSize):
                guard windowRecorder == nil, !isStartingVideo else { return }
                isStartingVideo = true
                defer { isStartingVideo = false }
                try await startVideo(in: window, withMic: withMic, cutSize: cutSize)
            case .screenshot(let atMs):
                isTakingScreenshot = true
                defer { isTakingScreenshot = false }
                try await saveScreenshot(of: window, at: atMs)
            }
        } catch {
            self.error = "Couldn't capture the window: \(error.localizedDescription)"
        }
    }

    private func startVideo(in window: SCWindow, withMic: Bool, cutSize: Bool) async throws {
        guard let meetingID, let startedAt, let folder = try? library.store?.meeting(meetingID)?.folder else { return }
        let atMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        let url = try MeetingFiles.newVideo(at: atMs, in: folder)
        let take = withMic ? try VideoMicRecorder() : nil
        videoMic.set(take)
        let requestedAt = mach_absolute_time()
        // Cut size takes at most an inch off the top (the browser's tabs and toolbar).
        let cutTop = cutSize ? ScreenCapture.inchShare(of: window) : nil
        let recorder: WindowRecorder
        do {
            recorder = try await WindowRecorder.start(window: window, to: url)
        } catch {
            videoMic.set(nil)
            throw error
        }
        recorder.onStop = { [weak self, weak recorder] failure in
            guard let self else { return }
            self.windowRecorder = nil
            self.isRecordingVideo = false
            if let failure { self.error = "The video stopped: \(failure)" }
            if take != nil || cutTop != nil {
                let startedAt = recorder?.startedHostTime ?? requestedAt
                self.finishVideo(url, mic: take, cutTop: cutTop, videoStartMs: self.meetingMs(atHostTime: startedAt), meetingID: meetingID)
            } else {
                self.scheduleFileWrite(meetingID)
            }
        }
        windowRecorder = recorder
        isRecordingVideo = true
        videos.append(MeetingScreenshot(url: url, atMs: atMs))
    }

    /// Finishes a video: mixes in the mic taken during it, once echo removal has handed over the last
    /// of it, and/or cuts it down to where the video is in the window, smaller.
    /// `cutTop`: cut size, taking at most this share of the height off the top.
    private func finishVideo(_ url: URL, mic take: VideoMicRecorder?, cutTop: Double?, videoStartMs: Int, meetingID: Int64) {
        finishingVideos.insert(url)
        let videoMic = videoMic
        let task = Task { [weak self] in
            var mic: VideoSoundMixer.Mic?
            if let take {
                try? await Task.sleep(for: .seconds(1.5))
                videoMic.set(nil)
                mic = take.finish().map { first in
                    VideoSoundMixer.Mic(url: take.url, startsAt: Double(first) / MonoResampler.sampleRate - Double(videoStartMs) / 1000)
                }
            }
            if mic != nil || cutTop != nil {
                let finished = url.deletingLastPathComponent().appending(path: ".finishing-" + url.lastPathComponent)
                do {
                    try await Task.detached(priority: .userInitiated) { [mic] in
                        var picture: VideoSoundMixer.Picture?
                        if let cutTop {
                            picture = VideoSoundMixer.Picture(crop: VideoArea.verticalCut(detected: await VideoArea.detect(in: url), topLimit: cutTop))
                        }
                        try await VideoSoundMixer.rewrite(video: url, mic: mic, picture: picture, into: finished)
                        _ = try FileManager.default.replaceItemAt(url, withItemAt: finished)
                    }.value
                } catch {
                    try? FileManager.default.removeItem(at: finished)
                    self?.error = error.localizedDescription
                }
            }
            withExtendedLifetime(take) {}
            guard let self else { return }
            self.finishingVideos.remove(url)
            self.scheduleFileWrite(meetingID)
        }
        videoMixes.append(task)
    }

    /// Meeting milliseconds at a host time.
    private func meetingMs(atHostTime time: UInt64) -> Int {
        time > startHostTime ? Int(Double(time - startHostTime) * Self.hostTicksPerMs) : 0
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
        await windowRecorder?.stop()
        stopHearing()
        await live.stopAll()
        liveFragments = [:]
        liveText = [:]
        whisperReachMs = [:]
        // Transcription hands the audio file the mic audio echo removal was still holding back.
        await pipeline.finish()
        await audioFile.recorder?.finish()
        // A video stopped with the recording gets the mic it took (needs the pipeline's last audio).
        for mix in videoMixes { await mix.value }
        videoMixes = []
        audioFile.set(nil)
        isSavingAudio = false
        // The last lines are still hopping to the main actor; let them land before the transcript is
        // read (and, later, saved).
        while undelivered.value > 0 { await Task.yield() }
        if let meetingID {
            save { try $0.endMeeting(meetingID, at: Date()) }
            fileWrite?.cancel()
            let hasSpeakers = saveSpeakers(pipeline.speakerResult(), meetingID: meetingID)
            library.writeFiles(meetingID)
            // Renamed while recording: now that nothing is being written, the folder follows the title.
            if let title = (try? library.store?.meeting(meetingID))?.title {
                library.rename(meetingID, to: title)
            }
            let summarize = !lines.isEmpty && UserDefaults.standard.object(forKey: MeetingLibrary.autoSummarizeKey) as? Bool ?? true
            if hasSpeakers {
                // Names first, so the summary can use them; naming (or skipping it) starts the summary.
                library.requestNaming(meetingID, thenSummarize: summarize)
            } else if summarize {
                Task { [library] in await library.summarize(meetingID) }
            }
        }
        library.refresh()
        self.pipeline = nil
        startedAt = nil
        phase = .idle
    }

    /// Applies the final participant numbers to the lines, and saves the voices and a sample clip
    /// of each in the meeting's folder. Returns whether any voices were told apart.
    private func saveSpeakers(_ result: SpeakerResult?, meetingID: Int64) -> Bool {
        guard let result, let folder = try? library.store?.meeting(meetingID)?.folder else { return false }
        let final = SpeakerTracker.finalParticipants(
            lines.map { ($0.id, $0.source, $0.startMs, $0.participant) }, renumber: result.renumber
        )
        for i in lines.indices { lines[i].participant = final[lines[i].id] }
        let speakers = result.profiles.enumerated().map { i, p in
            MeetingSpeaker(number: i + 1, sampleStartMs: p.sample.lowerBound, sampleEndMs: p.sample.upperBound, speechMs: p.speechMs)
        }
        var voiceprints: [Int: [Float]] = [:]
        for (i, p) in result.profiles.enumerated() { voiceprints[i + 1] = p.voiceprint }
        var assignments: [Int64: Int] = [:]
        for line in lines {
            if let id = segmentIDs[line.id], let participant = line.participant { assignments[id] = participant }
        }
        save { try $0.saveSpeakers(meetingID, speakers, voiceprints: voiceprints, lines: assignments) }
        for (number, clip) in result.clips {
            try? MeetingFiles.saveVoiceClip(clip, number: number, in: folder)
        }
        return !speakers.isEmpty
    }

    /// The app being recorded, which screenshots are limited to; nil when recording all system audio or
    /// the microphone only, where there's no app to capture.
    var screenshotApp: (bundleID: String, name: String)? {
        guard capture.captureSystemAudio, let id = capture.target.bundleID else { return nil }
        return (id, capture.target.label)
    }

    /// Screenshots the app being recorded into the meeting's folder, at the current point in the transcript.
    func takeScreenshot() async {
        guard phase == .recording, !isTakingScreenshot, windowChoices.isEmpty, let app = screenshotApp, let startedAt else { return }
        isTakingScreenshot = true
        defer { isTakingScreenshot = false }
        let atMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        do {
            guard let window = try await captureWindow(of: app, else: .screenshot(atMs: atMs)) else { return }
            try await saveScreenshot(of: window, at: atMs)
        } catch {
            self.error = "Couldn't take a screenshot: \(error.localizedDescription)"
        }
    }

    private func saveScreenshot(of window: SCWindow, at atMs: Int) async throws {
        guard let meetingID, let folder = try? library.store?.meeting(meetingID)?.folder else { return }
        let png = try await ScreenCapture.screenshot(of: window)
        screenshots.append(try MeetingFiles.saveScreenshot(png, at: atMs, in: folder))
        scheduleFileWrite(meetingID)
    }

    /// The window of `app` to capture. With several (a browser's): the one whose title shows a call
    /// or a video, else the one chosen earlier in this recording; if neither, nil, and it asks
    /// (`windowChoices`, answered with `chooseWindow`, which then does `pending`).
    private func captureWindow(of app: (bundleID: String, name: String), else pending: PendingCapture) async throws -> SCWindow? {
        guard ScreenCapture.hasPermission else {
            CGRequestScreenCaptureAccess()
            throw ScreenCaptureError.permission
        }
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let windows = ScreenCapture.windows(of: app.bundleID, in: content)
        guard !windows.isEmpty else { throw ScreenCaptureError.noWindow(app.name) }
        let byTitle = windows.count > 1 ? ScreenCapture.videoWindow(among: windows) : nil
        let known = windows.count == 1 ? windows[0] : byTitle ?? windows.first { $0.windowID == chosenWindow }
        liveLog.notice("capture window: \(windows.count) windows, \(windows.count == 1 ? "the only one" : byTitle != nil ? "by title" : known != nil ? "chosen before" : "asking", privacy: .public)")
        if let known { return known }
        pendingCapture = pending
        var choices: [CaptureWindowChoice] = []
        for window in windows.sorted(by: { $0.frame.width * $0.frame.height > $1.frame.width * $1.frame.height }) {
            choices.append(CaptureWindowChoice(id: window.windowID, title: window.title ?? app.name, preview: await ScreenCapture.preview(of: window)))
        }
        windowChoices = choices
        return nil
    }

    /// Takes a line from Whisper, unless the live recognizer heard no words where it was said. Its
    /// results lag a little and are only timed closely once finished, so a line it hasn't clearly
    /// heard gets one more look shortly after (unless it has stopped listening).
    private func insert(_ line: TranscriptLine, waited: Bool = false) {
        if line.source == .mic, mutedSpans.contains(where: { $0.contains((line.startMs + line.endMs) / 2) }) { return }
        if let heard = heard[line.source] {
            let final = waited || heard.until != nil
            switch heard.verdict(on: line) {
            case .heard: break
            case .unsure where final: break
            case .nothing where final:
                liveLog.notice("dropped a line the live recognizer heard no words in: \(line.text, privacy: .private)")
                return
            case .unsure, .nothing:
                undelivered.add(1)
                Task { [undelivered] in
                    try? await Task.sleep(for: .seconds(2))
                    self.insert(line, waited: true)
                    undelivered.add(-1)
                }
                return
            }
        }
        add(line)
    }

    private func add(_ line: TranscriptLine) {
        // Whisper's line replaces the live text for its stretch, even if it turns out to be echo.
        whisperReachMs[line.source] = max(whisperReachMs[line.source] ?? 0, line.endMs)
        updateLiveText(line.source)
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
                    meetingID: meetingID, source: line.source, startMs: line.startMs, endMs: line.endMs, text: line.text,
                    participant: line.participant
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

/// The audio file being written, swapped in from the main actor and fed from capture threads.
/// A stretch with the mic muted, in meeting milliseconds (no end: still muted).
struct MutedSpan {
    let startMs: Int
    var endMs: Int?

    func contains(_ ms: Int) -> Bool { ms >= startMs && endMs.map { ms < $0 } ?? true }
}

/// A switch read from capture threads.
private final class Flag: Sendable {
    private let value = Mutex(false)
    var isOn: Bool { value.withLock { $0 } }
    func set(_ on: Bool) { value.withLock { $0 = on } }
}

/// A window of the recorded app to choose for screenshots and videos.
struct CaptureWindowChoice: Identifiable {
    let id: CGWindowID
    let title: String
    let preview: CGImage?
}

/// The mic take of a "Record video + mic" video, swapped in from the main actor and fed from the
/// transcription pipeline.
private final class VideoMicBox: Sendable {
    private let value = Mutex<VideoMicRecorder?>(nil)
    func set(_ take: VideoMicRecorder?) { value.withLock { $0 = take } }
    func append(_ samples: [Float], at position: Int) { value.withLock { $0 }?.append(samples, at: position) }
}

private final class AudioFileBox: Sendable {
    private let value = Mutex<AudioFileRecorder?>(nil)
    var recorder: AudioFileRecorder? { value.withLock { $0 } }
    func set(_ recorder: AudioFileRecorder?) { value.withLock { $0 = recorder } }
    func append(_ samples: [Float], from source: AudioSource, at position: Int) {
        recorder?.append(samples, from: source, at: position)
    }
}

/// The live recognizers, per source: started from the main actor, fed from capture threads.
private final class LiveTranscriberBox: Sendable {
    private enum Entry {
        /// The recognizer is starting: audio waits here (up to `maxHeld` samples), so it hears the
        /// meeting from the start rather than from whenever it's ready.
        case starting(held: [(samples: [Float], position: Int)])
        case running(LiveTranscriber)
    }
    private static let maxHeld = Int(MonoResampler.sampleRate) * 15
    private let value = Mutex<[AudioSource: Entry]>([:])

    func has(_ source: AudioSource) -> Bool { value.withLock { $0[source] != nil } }
    /// Starts holding the source's audio for a recognizer about to start.
    func expect(_ source: AudioSource) { value.withLock { $0[source] = .starting(held: []) } }
    func cancel(_ source: AudioSource) { value.withLock { $0[source] = nil } }

    /// Hands the recognizer the audio held for it, and the rest as it comes. Returns the sample
    /// position it hears from (nil: none held, so from now on).
    func set(_ transcriber: LiveTranscriber, for source: AudioSource) -> Int? {
        value.withLock { all in
            var first: Int?
            if case .starting(let held)? = all[source] {
                first = held.first?.position
                for chunk in held { transcriber.append(chunk.samples, at: chunk.position) }
            }
            all[source] = .running(transcriber)
            return first
        }
    }

    func append(_ samples: [Float], from source: AudioSource, at position: Int) {
        let running: LiveTranscriber? = value.withLock { all in
            switch all[source] {
            case .running(let transcriber)?: return transcriber
            case .starting(var held)?:
                held.append((samples, position))
                var count = held.reduce(0) { $0 + $1.samples.count }
                while count > Self.maxHeld, !held.isEmpty { count -= held.removeFirst().samples.count }
                all[source] = .starting(held: held)
                return nil
            case nil: return nil
            }
        }
        running?.append(samples, at: position)
    }

    func stopAll() async {
        let all = value.withLock { all in
            defer { all = [:] }
            return all.values.compactMap { entry -> LiveTranscriber? in
                if case .running(let transcriber) = entry { return transcriber }
                return nil
            }
        }
        for transcriber in all { await transcriber.stop() }
    }
}
