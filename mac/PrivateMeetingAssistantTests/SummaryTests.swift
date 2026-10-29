import Foundation
import Testing
@testable import Private_Meeting_Assistant

struct SummarizerTests {
    @Test func parsesJSONWrappedInProse() throws {
        let raw = """
            Here you go:
            ```json
            {"summary":"S","decisions":["D"],"actionItems":[{"text":"T","owner":"null"},{"text":" ","owner":"Me"},{"text":"U","owner":"Priya"}]}
            ```
            """
        let s = try Summarizer.parse(raw)
        #expect(s.summary == "S" && s.decisions == ["D"])
        #expect(s.actionItems.map(\.text) == ["T", "U"])
        #expect(s.actionItems.map(\.owner) == [nil, "Priya"])
        #expect(throws: Summarizer.Failure.self) { try Summarizer.parse("no json here") }
    }

    /// A seven-second "Ah!" and a row of typed s's: nothing to summarize, so no model is asked
    /// (Apple's made up a product launch from it).
    @Test func tooLittleSaidIsNotSummarized() async throws {
        let segments = [Segment(id: 1, meetingID: 1, source: .mic, startMs: 2_000, endMs: 3_000, text: "Ah!", speaker: "Me")]
        let summary = try await Summarizer(backend: .apple).summarize(segments, notes: "ssssssssssss")
        #expect(summary == MeetingSummary(summary: Summarizer.tooLittle))
        #expect(Summarizer.wordCount("Okay, this is... — ✓ 42") == 4)
    }

    /// Models copy the prompt's "Participant N" when they can't tell who owns a task: no owner
    /// then, and none shown for summaries saved with one.
    @Test func placeholderOwnersAreDropped() {
        let raw = MeetingSummary(summary: "S", actionItems: [
            .init(text: "Review the map", owner: "Participant N"),
            .init(text: "Send the deck", owner: "Participant 2"),
            .init(text: "Book the room", owner: "Participant 7"),
            .init(text: "Write notes", owner: "Me"),
            .init(text: "Call the vendor", owner: "Unknown"),
        ])
        let present: Set<String> = ["participant 2", "me"]
        let cleaned = Summarizer.cleaned(raw) { present.contains($0.lowercased()) }
        #expect(cleaned.actionItems.map(\.owner) == [nil, "Participant 2", nil, "Me", nil])
        // Saved before owners were checked: shown without one.
        #expect(MeetingSummary.ActionItem(text: "Review the map", owner: "Participant N").shownOwner == nil)
        #expect(MeetingSummary.ActionItem(text: "Send the deck", owner: "Priya").shownOwner == "Priya")
    }

    @Test func chunksRespectTheLimit() {
        let text = (0..<100).map { "line \($0) " + String(repeating: "x", count: 50) }.joined(separator: "\n")
        let chunks = Summarizer.chunkLines(text, max: 500)
        #expect(chunks.count > 10)
        #expect(chunks.allSatisfy { $0.count <= 500 })
        #expect(chunks.joined(separator: "\n") == text)
    }

    @Test func comparesVersions() {
        #expect(SummaryEngine.isAtLeast("0.40.11", "0.9.0"))
        #expect(SummaryEngine.isAtLeast("0.9.0", "0.9.0"))
        #expect(!SummaryEngine.isAtLeast("0.5.7", "0.9.0"))
    }

    @Test func rejectsUnsignedBinaries() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "fake-ollama-\(UUID().uuidString)")
        try Data("#!/bin/sh\necho hi\n".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(!SummaryEngine.isSignedByOllama(file))
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: "/usr/local/bin/ollama")))
    func acceptsOllamasSignature() {
        let installed = URL(fileURLWithPath: "/usr/local/bin/ollama").resolvingSymlinksInPath()
        #expect(SummaryEngine.isSignedByOllama(installed))
    }
}

/// Talks to the Ollama on this Mac, so it only runs when it's up with the recommended model
/// (ported from the prototype's ollama_produces_structured_summary).
@Suite(.enabled(if: ProcessInfo.processInfo.environment["SUMMARY_LIVE"] != nil, "set TEST_RUNNER_SUMMARY_LIVE=1"))
struct LiveSummaryTests {
    @Test(.timeLimit(.minutes(5)))
    func writesAStructuredSummary() async throws {
        let lines: [(AudioSource, String)] = [
            (.system, "Thanks for joining. Today we need to settle the pricing for the new plan."),
            (.mic, "I think we should go with nineteen dollars a month."),
            (.system, "Agreed, nineteen it is. Priya will send the updated pricing deck by Friday."),
            (.mic, "Great. I'll update the website copy and share it on Monday."),
            (.system, "Perfect, let's also move the launch review to Thursday."),
        ]
        let segments = lines.enumerated().map { i, line in
            Segment(id: Int64(i), meetingID: 1, source: line.0, startMs: i * 5_000, endMs: i * 5_000 + 4_000, text: line.1)
        }
        let model = SummaryEngine.recommendedModel.name
        let summary = try await Summarizer(backend: .ollama(SummaryEngine.yoursURL, model: model)).summarize(segments)
        print("summary:", summary)
        #expect(summary.summary.lowercased().contains("pric"))
        #expect(summary.actionItems.count >= 2)
        #expect(summary.actionItems.allSatisfy { !$0.text.contains("\n") })
        #expect(summary.actionItems.contains { $0.owner == "Me" })
        #expect(!summary.decisions.isEmpty)
    }
}

/// Apple's on-device model, when Apple Intelligence is on: a real summary through the same path the
/// App Store build uses by default.
@Suite(.enabled(if: SummaryEngine.appleProblem == nil, "Apple Intelligence isn't available"))
struct AppleSummaryTests {
    @Test(.timeLimit(.minutes(3)))
    func summarizesWithAppleIntelligence() async throws {
        // Voices told apart, as in a recording: the owner should be the voice that took the task on.
        let lines: [(AudioSource, Int?, String)] = [
            (.system, 1, "Thanks for joining. The App Store build is ready for review."),
            (.mic, nil, "Great. Let's submit it on Monday, and I'll write the release notes."),
            (.system, 2, "Agreed. I'll prepare the screenshots by Friday."),
        ]
        let segments = lines.enumerated().map { i, line in
            Segment(
                id: Int64(i), meetingID: 1, source: line.0, startMs: i * 5_000, endMs: i * 5_000 + 4_000, text: line.2,
                participant: line.1, speaker: line.1.map { "Participant \($0)" } ?? line.0.speaker
            )
        }
        let summary = try await Summarizer(backend: .apple).summarize(segments)
        print("apple summary: \(summary)")
        #expect(!summary.summary.isEmpty)
        #expect(summary.actionItems.contains { $0.text.lowercased().contains("screenshot") && $0.owner == "Participant 2" })
    }

    /// Small talk while testing the mic: long enough to go to the model, but nothing was decided
    /// or taken on, so none should be made up.
    @Test(.timeLimit(.minutes(3)))
    func smallTalkGetsNoInventedItems() async throws {
        let lines = [
            "Hello, can you hear me okay?",
            "Yes, I can hear you fine.",
            "Okay, let me test the microphone one more time.",
            "Sounds good, it works now.",
        ]
        let segments = lines.enumerated().map { i, text in
            Segment(id: Int64(i), meetingID: 1, source: i % 2 == 0 ? .mic : .system, startMs: i * 3_000, endMs: i * 3_000 + 2_500, text: text,
                    speaker: i % 2 == 0 ? "Me" : "Them")
        }
        let summary = try await Summarizer(backend: .apple).summarize(segments)
        print("apple small talk: \(summary)")
        #expect(summary.decisions.isEmpty)
        #expect(summary.actionItems.isEmpty)
    }
}

/// Regenerate uses the engine set in Settings at that moment, and the summary says which wrote it.
/// Runs Apple's model and your Ollama (each only if it's there); the engine setting is put back.
@Suite(.serialized)
struct SummaryEngineSwitchTests {
    @MainActor @Test(.timeLimit(.minutes(5)))
    func regenerateFollowsTheEngineSetting() async throws {
        let store = try MeetingStore.inMemory()
        let root = FileManager.default.temporaryDirectory.appending(path: "engine-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let started = Date()
        let folder = try MeetingFiles.createFolder(in: root, title: "Meeting", startedAt: started)
        let id = try store.createMeeting(title: "Meeting", startedAt: started, folder: folder)
        for (i, text) in ["The App Store build is ready for review, thanks everyone for joining today.",
                          "Great. Let's submit it on Monday, and I'll write the release notes tonight.",
                          "Agreed. I'll prepare the screenshots by Friday and send them over."].enumerated() {
            _ = try store.insertSegment(meetingID: id, source: i == 1 ? .mic : .system, startMs: i * 5_000, endMs: i * 5_000 + 4_000, text: text)
        }
        let library = MeetingLibrary(store: store)
        let defaults = UserDefaults.standard
        let saved = defaults.string(forKey: MeetingLibrary.summaryEngineKey)
        defer { defaults.set(saved, forKey: MeetingLibrary.summaryEngineKey) }

        await SummaryEngine.shared.refresh()
        var engines: [(SummaryEngine.Choice, String)] = []
        if SummaryEngine.appleProblem == nil { engines.append((.apple, "Apple Intelligence")) }
        if SummaryEngine.shared.yours.problem == nil, SummaryEngine.shared.yours.models.contains(MeetingLibrary.summaryModel) {
            engines.append((.yours, "in your Ollama"))
        }
        for (choice, expected) in engines {
            defaults.set(choice.rawValue, forKey: MeetingLibrary.summaryEngineKey)
            await library.summarize(id)
            let meeting = try store.meeting(id)
            let summary = try #require(meeting?.summary, "\(meeting?.summaryStatus ?? "")")
            print("engine switch: \(choice.rawValue) → \(summary.writtenBy ?? "nil")")
            #expect(summary.writtenBy?.contains(expected) == true, "\(choice.rawValue): \(summary.writtenBy ?? "nil")")
        }
    }
}
