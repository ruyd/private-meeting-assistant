import AVFoundation
import Foundation

/// Meetings as plain files people can open, share and back up: one folder per meeting inside the
/// folder they chose, named "<Subject> - <date time>", with transcript.md and, once there is one,
/// summary.md, and screenshots in screenshots/. The database is only an index for the meetings list
/// and search.
enum MeetingFiles {
    static let rootKey = "meetingsFolder"
    static let transcriptFile = "transcript.md"
    static let summaryFile = "summary.md"
    static let screenshotsFolder = "screenshots"
    static let voicesFolder = "voices"
    static let audioFile = "audio.m4a"
    static let videosFolder = "video"

    /// The folder chosen in setup or Settings; nil until chosen. In the App Store build (sandboxed)
    /// it's only available while the app holds access to it, which it gets back at launch from a
    /// bookmark saved when the folder was chosen.
    static var root: URL? {
        get {
            #if APPSTORE
            _ = FolderAccess.restored
            guard let path = UserDefaults.standard.string(forKey: rootKey), FolderAccess.isGranted(path) else { return nil }
            #else
            guard let path = UserDefaults.standard.string(forKey: rootKey) else { return nil }
            #endif
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        set {
            #if APPSTORE
            if let newValue { FolderAccess.remember(newValue) }
            #endif
            UserDefaults.standard.set(newValue?.path, forKey: rootKey)
        }
    }

    /// The person's home folder. In the sandbox, `URL.homeDirectory` is the app's own container.
    static var realHome: URL {
        if let dir = getpwuid(getuid())?.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return URL.homeDirectory
    }

    /// A path for display, with the home folder as "~".
    static func displayPath(_ url: URL) -> String {
        url.path.replacingOccurrences(of: realHome.path, with: "~")
    }

    /// Suggested in setup: ~/Meetings. Unlike Documents or Desktop, macOS doesn't ask permission for it.
    /// The App Store build can't create it unasked; there, the folder is chosen in an open panel.
    static var suggestedRoot: URL { realHome.appending(path: "Meetings", directoryHint: .isDirectory) }

    /// Whether the suggested folder can be used without asking (outside the sandbox).
    #if APPSTORE
    static let canUseSuggestedRoot = false
    #else
    static let canUseSuggestedRoot = true
    #endif

    /// "Pricing sync - 2026-10-28 14.30": readable, sorts by subject, and the time tells apart two
    /// meetings with the same subject on one day.
    static func folderName(title: String, startedAt: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: startedAt)
        let date = String(format: "%04d-%02d-%02d %02d.%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0)
        return "\(TranscriptExport.fileName(title)) - \(date)"
    }

    /// Creates the meeting's folder under `root`, adding " (2)", " (3)"… if the name is taken.
    static func createFolder(in root: URL, title: String, startedAt: Date) throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let base = folderName(title: title, startedAt: startedAt)
        var url = root.appending(path: base, directoryHint: .isDirectory)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = root.appending(path: "\(base) (\(n))", directoryHint: .isDirectory)
            n += 1
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    /// Renames the folder for a new title, keeping its date. Returns the new location.
    static func renameFolder(_ folder: URL, title: String, startedAt: Date) throws -> URL {
        let parent = folder.deletingLastPathComponent()
        let base = folderName(title: title, startedAt: startedAt)
        var target = parent.appending(path: base, directoryHint: .isDirectory)
        var n = 2
        while FileManager.default.fileExists(atPath: target.path), target.standardizedFileURL != folder.standardizedFileURL {
            target = parent.appending(path: "\(base) (\(n))", directoryHint: .isDirectory)
            n += 1
        }
        guard target.standardizedFileURL != folder.standardizedFileURL else { return folder }
        try FileManager.default.moveItem(at: folder, to: target)
        return target
    }

    /// Writes transcript.md, and summary.md if the meeting has a summary (removing a stale one if not).
    static func write(_ meeting: Meeting, _ segments: [Segment], to folder: URL) throws {
        let hasAudio = FileManager.default.fileExists(atPath: folder.appending(path: audioFile).path)
        try transcriptMarkdown(meeting, segments, screenshots: screenshots(in: folder), videos: videos(in: folder), hasAudio: hasAudio)
            .write(to: folder.appending(path: transcriptFile), atomically: true, encoding: .utf8)
        let summaryURL = folder.appending(path: summaryFile)
        if let summary = meeting.summary {
            try summaryMarkdown(meeting, summary).write(to: summaryURL, atomically: true, encoding: .utf8)
        } else if FileManager.default.fileExists(atPath: summaryURL.path) {
            try FileManager.default.removeItem(at: summaryURL)
        }
    }

    /// The transcript, with each screenshot and video placed where it was taken, and a link to the
    /// audio recording if there is one.
    static func transcriptMarkdown(
        _ meeting: Meeting, _ segments: [Segment], screenshots: [MeetingScreenshot] = [], videos: [MeetingScreenshot] = [],
        hasAudio: Bool = false
    ) -> String {
        var out = "# \(meeting.title)\n\n*\(heading(meeting))*\n\n" + participantsMarkdown(meeting)
        if hasAudio { out += "*Audio: [\(audioFile)](<\(audioFile)>)*\n\n" }
        // Screenshots and videos, in meeting order.
        var media = (screenshots.map { ($0, false) } + videos.map { ($0, true) }).sorted { $0.0.atMs < $1.0.atMs }[...]
        func embed(_ item: (MeetingScreenshot, Bool)) -> String {
            let (file, isVideo) = item
            let time = TranscriptExport.timestamp(file.atMs)
            return isVideo
                ? "*Video from \(time): [\(file.url.lastPathComponent)](<\(videosFolder)/\(file.url.lastPathComponent)>)*\n\n"
                : "![Screenshot at \(time)](<\(screenshotsFolder)/\(file.url.lastPathComponent)>)\n\n"
        }
        for s in segments {
            while let item = media.first, item.0.atMs <= s.startMs {
                out += embed(item)
                media.removeFirst()
            }
            out += "**[\(TranscriptExport.timestamp(s.startMs))] \(s.speaker.isEmpty ? s.source.speaker : s.speaker):** \(s.text)\n\n"
        }
        for item in media { out += embed(item) }
        return out
    }

    // MARK: Voice samples

    /// A short clip of each voice told apart, voices/participant-<n>.wav, to tell who's who when
    /// naming them. 16 kHz mono.
    static func voiceClip(_ number: Int, in folder: URL) -> URL {
        folder.appending(path: voicesFolder, directoryHint: .isDirectory).appending(path: "participant-\(number).wav")
    }

    static func saveVoiceClip(_ samples: [Float], number: Int, in folder: URL) throws {
        let url = voiceClip(number, in: folder)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let format = AVAudioFormat(standardFormatWithSampleRate: MonoResampler.sampleRate, channels: 1)!
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        // Written as 16-bit WAV, half the size and playable anywhere.
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: MonoResampler.sampleRate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
    }

    // MARK: Screenshots

    /// Saves a screenshot in the meeting's screenshots/ folder, named by when it was taken in the meeting
    /// ("00.13.21.png") so the folder sorts in meeting order.
    static func saveScreenshot(_ png: Data, at ms: Int, in folder: URL) throws -> MeetingScreenshot {
        let url = try timedFile(at: ms, in: folder.appending(path: screenshotsFolder, directoryHint: .isDirectory), extension: "png")
        try png.write(to: url)
        return MeetingScreenshot(url: url, atMs: ms)
    }

    /// Where a video started `ms` into the meeting goes: video/00.13.21.mp4.
    static func newVideo(at ms: Int, in folder: URL) throws -> URL {
        try timedFile(at: ms, in: folder.appending(path: videosFolder, directoryHint: .isDirectory), extension: "mp4")
    }

    /// A file in `dir` named by its time in the meeting, adding " (2)", " (3)"… if taken.
    private static func timedFile(at ms: Int, in dir: URL, extension ext: String) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let s = max(ms, 0) / 1000
        let base = String(format: "%02d.%02d.%02d", s / 3600, (s / 60) % 60, s % 60)
        var url = dir.appending(path: "\(base).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appending(path: "\(base) (\(n)).\(ext)")
            n += 1
        }
        return url
    }

    /// The meeting's screenshots in meeting order; the time comes from the file name.
    static func screenshots(in folder: URL) -> [MeetingScreenshot] {
        timedFiles(in: folder.appending(path: screenshotsFolder, directoryHint: .isDirectory), extension: "png")
    }

    /// The meeting's videos in meeting order, by when each started.
    static func videos(in folder: URL) -> [MeetingScreenshot] {
        timedFiles(in: folder.appending(path: videosFolder, directoryHint: .isDirectory), extension: "mp4")
    }

    private static func timedFiles(in dir: URL, extension ext: String) -> [MeetingScreenshot] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension.lowercased() == ext }
            .compactMap { url -> MeetingScreenshot? in
                let parts = url.lastPathComponent.prefix(8).split(separator: ".").compactMap { Int($0) }
                guard parts.count == 3 else { return nil }
                return MeetingScreenshot(url: url, atMs: (parts[0] * 3600 + parts[1] * 60 + parts[2]) * 1000)
            }
            // Without the extension, so "00.13.21" comes before "00.13.21 (2)".
            .sorted { ($0.atMs, $0.url.deletingPathExtension().lastPathComponent) < ($1.atMs, $1.url.deletingPathExtension().lastPathComponent) }
    }

    static func summaryMarkdown(_ meeting: Meeting, _ s: MeetingSummary) -> String {
        "# \(meeting.title)\n\n*\(heading(meeting))*\n\n" + participantsMarkdown(meeting) + summarySections(s)
    }

    /// The summary, decisions and action items as Markdown: summary.md without its title, and what
    /// the summary's copy button puts on the clipboard.
    static func summarySections(_ s: MeetingSummary) -> String {
        var out = "## Summary\n\n\(s.summary.trimmingCharacters(in: .whitespacesAndNewlines))\n\n"
        if !s.decisions.isEmpty {
            out += "## Decisions\n\n" + s.decisions.map { "- \($0)\n" }.joined() + "\n"
        }
        if !s.actionItems.isEmpty {
            out += "## Action items\n\n" + s.actionItems.map { a in
                "- [\(a.done ? "x" : " ")] \(a.text)\(a.owner.map { " — *\($0)*" } ?? "")\n"
            }.joined() + "\n"
        }
        return out
    }

    /// Who was invited, from the linked calendar or Zoom: the recorder ("Me") first, then the organizer
    /// and everyone else. Empty when the meeting wasn't started from a calendar entry.
    static func participantsMarkdown(_ meeting: Meeting) -> String {
        guard let details = meeting.details, !details.participants.isEmpty else { return "" }
        var out = "## Participants\n\n"
        for p in details.participants.filter(\.isMe) + details.others {
            out += "- \(participantLine(p))\n"
        }
        if let platform = details.platform {
            out += "\n*\(platform.name)\(details.joinURL.map { ": <\($0.absoluteString)>" } ?? "")*\n"
        }
        return out + "\n"
    }

    static func participantLine(_ p: MeetingParticipant) -> String {
        var line = p.displayName
        if let email = p.email, p.name?.nilIfBlank != nil { line += " <\(email)>" }
        var notes: [String] = []
        if p.isMe { notes.append("Me") }
        if p.role == .organizer { notes.append("organizer") }
        if p.role == .optional { notes.append("optional") }
        if p.response == .declined { notes.append("declined") }
        if p.response == .tentative { notes.append("tentative") }
        return notes.isEmpty ? line : "\(line) — \(notes.joined(separator: ", "))"
    }

    private static func heading(_ meeting: Meeting) -> String {
        let date = meeting.startedAt.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().year().hour().minute())
        return "\(date) · \((meeting.durationMs + 59_999) / 60_000) min"
    }
}

/// A screenshot taken (or a video started) during a meeting, `atMs` milliseconds from the start.
struct MeetingScreenshot: Identifiable, Hashable, Sendable {
    let url: URL
    let atMs: Int

    var id: URL { url }
}

#if APPSTORE
/// Access to the meetings folders chosen in the sandboxed App Store build: a security-scoped bookmark
/// per folder ever chosen (older meetings stay where they were when the folder changes), resolved at
/// launch so their files can be read and written.
enum FolderAccess {
    private static let key = "meetingsFolderBookmarks"
    nonisolated(unsafe) private static var granted: Set<String> = []

    /// Resolves the saved bookmarks once, at first use.
    static let restored: Void = {
        var refreshed: [Data] = []
        for data in UserDefaults.standard.array(forKey: key) as? [Data] ?? [] {
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, bookmarkDataIsStale: &stale),
                  url.startAccessingSecurityScopedResource()
            else { continue }
            granted.insert(url.standardizedFileURL.path)
            refreshed.append(stale ? (try? url.bookmarkData(options: .withSecurityScope)) ?? data : data)
        }
        UserDefaults.standard.set(refreshed, forKey: key)
    }()

    static func isGranted(_ path: String) -> Bool {
        let path = URL(fileURLWithPath: path).standardizedFileURL.path
        return granted.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    /// Keeps access to a folder chosen in an open panel (or inside the app's own container).
    static func remember(_ url: URL) {
        _ = restored
        guard !isGranted(url.path), let data = try? url.bookmarkData(options: .withSecurityScope) else { return }
        _ = url.startAccessingSecurityScopedResource()
        granted.insert(url.standardizedFileURL.path)
        UserDefaults.standard.set((UserDefaults.standard.array(forKey: key) as? [Data] ?? []) + [data], forKey: key)
    }
}
#endif
