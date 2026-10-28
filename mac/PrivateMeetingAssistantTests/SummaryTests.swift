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
}
