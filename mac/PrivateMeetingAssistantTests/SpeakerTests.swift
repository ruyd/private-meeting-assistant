import AVFoundation
import Foundation
import Synchronization
import Testing
@testable import Private_Meeting_Assistant

struct SpeakerTrackerTests {
    /// A voiceprint near `direction` (one of a few orthogonal "voices"), with a little noise.
    private func voice(_ direction: Int, noise: Float = 0.1, seed: inout UInt64) -> [Float] {
        (0..<64).map { i in
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let n = (Float(seed >> 40) / Float(1 << 24) * 2 - 1) * noise
            return (i == direction ? 1 : 0) + n
        }.normalizedForTest
    }

    @Test func tellsVoicesApartAndNumbersThemByFirstSpeaking() {
        var tracker = SpeakerTracker()
        var seed: UInt64 = 1
        var at = 0
        func say(_ direction: Int?, ms: Int = 4_000) -> Int? {
            defer { at += ms + 500 }
            return tracker.assign(direction.map { voice($0, seed: &seed) }, source: .system, startMs: at, endMs: at + ms).participant
        }
        #expect(say(0) == 1)
        #expect(say(1) == 2)
        #expect(say(0) == 1)
        #expect(say(2) == 3)
        // Too short for a voiceprint: whoever spoke last on that source.
        #expect(say(nil, ms: 800) == 3)
        #expect(say(1) == 2)

        let (profiles, renumber) = tracker.finished()
        #expect(profiles.count == 3)
        #expect(renumber == [1: 1, 2: 2, 3: 3])
        #expect(profiles[0].speechMs == 8_000)
    }

    @Test func mergesTheSameVoiceAndFoldsStrayOnes() {
        var tracker = SpeakerTracker()
        var seed: UInt64 = 7
        let c = voice(3, seed: &seed)
        let a = voice(0, noise: 0, seed: &seed)
        // The same person sounding different at first (0.4 alike, under the 0.45 to join live)…
        let b = zip(a, voice(5, noise: 0, seed: &seed)).map { $0 * 0.4 + $1 * 0.9165 }.normalizedForTest
        // …then speaking in between, which pulls the first profile towards the second.
        let between = zip(a, b).map { $0 + $1 }.normalizedForTest
        // A one-second stray sound, somewhat like `c`.
        let stray = zip(c, voice(9, noise: 0, seed: &seed)).map { $0 * 0.4 + $1 * 0.9165 }.normalizedForTest

        var at = 0
        func say(_ v: [Float], ms: Int = 4_000) {
            _ = tracker.assign(v, source: .system, startMs: at, endMs: at + ms)
            at += ms + 500
        }
        say(c, ms: 5_000)
        say(a)
        say(b)
        for _ in 0..<4 { say(between) }
        say(stray, ms: 1_000)
        #expect(tracker.profiles.count == 4)

        let (profiles, renumber) = tracker.finished()
        #expect(profiles.count == 2, "\(profiles.map(\.speechMs))")
        #expect(renumber[1] == 1 && renumber[4] == 1)
        #expect(renumber[2] == 2 && renumber[3] == 2)
    }

    @Test func linesWithoutAVoiceGetTheirNeighbour() {
        let lines: [(id: Int, source: AudioSource, startMs: Int, participant: Int?)] = [
            (1, .mic, 0, nil),
            (2, .mic, 1_000, 2),
            (3, .system, 1_500, nil),
            (4, .mic, 9_000, 3),
        ]
        let final = SpeakerTracker.finalParticipants(lines, renumber: [2: 1, 3: 1])
        #expect(final == [1: 1, 2: 1, 4: 1])
    }
}

struct SpeakerStorageTests {
    @Test func savesVoicesNamesAndLabels() throws {
        let store = try MeetingStore.inMemory()
        let id = try store.createMeeting(title: "Workshop", startedAt: Date(), folder: URL(fileURLWithPath: "/tmp/w"))
        let a = try store.insertSegment(meetingID: id, source: .mic, startMs: 0, endMs: 3_000, text: "Welcome everyone to the workshop.", participant: 1)
        let b = try store.insertSegment(meetingID: id, source: .mic, startMs: 4_000, endMs: 7_000, text: "Thanks, glad to be here.", participant: 2)
        try store.saveSpeakers(
            id,
            [
                MeetingSpeaker(number: 1, sampleStartMs: 0, sampleEndMs: 3_000, speechMs: 3_000),
                MeetingSpeaker(number: 2, sampleStartMs: 4_000, sampleEndMs: 7_000, speechMs: 3_000),
            ],
            voiceprints: [1: [0.6, 0.8]], lines: [a: 1, b: 2]
        )
        #expect(try store.segments(of: id).map(\.speaker) == ["Participant 1", "Participant 2"])

        try store.nameSpeakers(id, [1: "Priya", 2: "  "])
        let speakers = try store.speakers(of: id)
        #expect(speakers.map(\.label) == ["Priya", "Participant 2"])
        #expect(try store.segments(of: id).map(\.speaker) == ["Priya", "Participant 2"])

        let hit = try #require(try store.search("workshop").first { $0.kind == .transcript })
        #expect(hit.speaker == "Priya" && hit.participant == 1)

        let meeting = try #require(try store.meeting(id))
        let md = MeetingFiles.transcriptMarkdown(meeting, try store.segments(of: id))
        #expect(md.contains("] Priya:** Welcome"))
        #expect(md.contains("] Participant 2:** Thanks"))

        // Lines without a participant keep Me / Them.
        _ = try store.insertSegment(meetingID: id, source: .system, startMs: 8_000, endMs: 9_000, text: "Hi.")
        #expect(try store.segments(of: id).last?.speaker == "Them")
    }
}

/// Real models: the speaker model and a speech model must be downloaded (the app fetches the
/// speaker model when "Tell speakers apart" is on). Voices are synthesized with macOS's `say`.
@Suite(.enabled(if: VoiceprintModel.isDownloaded && SpeechModel.catalog.contains(where: ModelStore.isComplete), "models not downloaded"))
struct SpeakerPipelineTests {
    private func synthesize(_ text: String, voice: String) throws -> [Float] {
        let url = FileManager.default.temporaryDirectory.appending(path: "say-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-v", voice, "-o", url.path, "--file-format=WAVE", "--data-format=LEF32@16000", text]
        try say.run()
        say.waitUntilExit()
        let file = try AVAudioFile(forReading: url)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        return try MonoResampler().convert(buffer)
    }

    @Test(.timeLimit(.minutes(10)))
    func threeVoicesInTheRoomBecomeThreeParticipants() async throws {
        let model = try #require(
            ModelStore.isComplete(SpeechModel.recommended) ? SpeechModel.recommended : SpeechModel.catalog.first(where: ModelStore.isComplete)
        )
        let transcriber = try await Transcriber.load(model)
        let voiceprinter = try #require(Voiceprinter.load())

        // A conversation: each turn, then a second of quiet so the segmenter cuts there.
        let turns = [
            ("Daniel", "Good morning everyone, thanks for joining the planning session today."),
            ("Karen", "Happy to be here. I brought the numbers from the last quarter."),
            ("Rishi", "Great, I also have an update on the hiring plan for the new team."),
            ("Daniel", "Let's start with the numbers and then move on to hiring."),
            ("Karen", "Revenue grew by twelve percent, mostly from the enterprise customers."),
            ("Rishi", "That's good news, it means we can open two more positions."),
        ]
        var stream = [Float](repeating: 0, count: 8_000)
        var expected: [(startMs: Int, voice: String)] = []
        for (voice, text) in turns {
            expected.append((stream.count * 1000 / 16_000, voice))
            stream += try synthesize(text, voice: voice) + [Float](repeating: 0, count: 16_000)
        }

        let lines = Mutex<[TranscriptLine]>([])
        let start = mach_absolute_time()
        let pipeline = TranscriptionPipeline(
            transcriber: transcriber, language: "en", startHostTime: start, removeEcho: false,
            voiceprinter: voiceprinter, identifySpeakers: [.mic],
            onLine: { line in lines.withLock { $0.append(line) } },
            onBacklog: { _ in }
        )
        for offset in stride(from: 0, to: stream.count, by: 1_600) {
            let hostTime = start + AVAudioTime.hostTime(forSeconds: Double(offset) / 16_000)
            pipeline.append(AudioChunk(source: .mic, samples: Array(stream[offset..<min(offset + 1_600, stream.count)]), hostTime: hostTime))
        }
        await pipeline.finish()

        let result = try #require(pipeline.speakerResult())
        let all = lines.withLock { $0 }
        let final = SpeakerTracker.finalParticipants(all.map { ($0.id, $0.source, $0.startMs, $0.participant) }, renumber: result.renumber)

        // Which voice each line came from: the turn it starts in.
        var byVoice: [String: Set<Int>] = [:]
        for line in all {
            guard let turn = expected.min(by: { abs($0.startMs - line.startMs) < abs($1.startMs - line.startMs) }),
                  let p = final[line.id] else { continue }
            byVoice[turn.voice, default: []].insert(p)
        }
        let summary = all.map { "\($0.startMs) P\(final[$0.id] ?? 0): \($0.text)" }.joined(separator: "\n")
        #expect(result.profiles.count == 3, "\(summary)")
        #expect(byVoice["Daniel"] == [1] && byVoice["Karen"] == [2] && byVoice["Rishi"] == [3], "\(byVoice)\n\(summary)")
        #expect(result.clips.count == 3)
    }
}

private extension Array where Element == Float {
    var normalizedForTest: [Float] { SpeakerTracker.normalized(self) }
}

@MainActor
struct SpeakerNamingTests {
    @Test func namingSavesNamesAndClearsTheRequest() throws {
        let store = try MeetingStore.inMemory()
        let folder = FileManager.default.temporaryDirectory.appending(path: "naming-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let id = try store.createMeeting(title: "Naming", startedAt: Date(), folder: folder)
        let line = try store.insertSegment(meetingID: id, source: .system, startMs: 0, endMs: 3_000, text: "Hello.", participant: 1)
        try store.saveSpeakers(id, [MeetingSpeaker(number: 1, sampleStartMs: 0, sampleEndMs: 3_000, speechMs: 3_000)], voiceprints: [:], lines: [line: 1])
        let library = MeetingLibrary(store: store)

        library.requestNaming(id, thenSummarize: false)
        library.nameSpeakers(id, [1: "Ana"])
        #expect(library.namingRequest == nil)
        #expect(try store.speakers(of: id).first?.name == "Ana")
        #expect(try String(contentsOf: folder.appending(path: MeetingFiles.transcriptFile), encoding: .utf8).contains("Ana:** Hello."))
    }
}
