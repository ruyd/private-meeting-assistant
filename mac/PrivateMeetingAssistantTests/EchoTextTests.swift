import Testing
@testable import Private_Meeting_Assistant

struct EchoTextTests {
    let them = TranscriptLine(
        source: .system, startMs: 18_000, endMs: 23_000,
        text: "Think it over and call me on Monday morning. The board meets on Thursday and they want an answer before then."
    )

    @Test func dropsAGarbledRepeatOfThem() {
        // A real leak from the replay test: Whisper heard the echo slightly differently.
        let me = TranscriptLine(
            source: .mic, startMs: 19_470, endMs: 23_600,
            text: "Thank you for calling me on Monday morning. The bar waits on Thursday and they want an answer before then."
        )
        #expect(EchoText.isEcho(me, of: [them]))
    }

    @Test func keepsYourOwnWords() {
        let me = TranscriptLine(source: .mic, startMs: 19_000, endMs: 21_000, text: "Can everyone review the contract by end of day tomorrow?")
        #expect(!EchoText.isEcho(me, of: [them]))
    }

    @Test func keepsShortRepliesAndOtherMoments() {
        let short = TranscriptLine(source: .mic, startMs: 19_000, endMs: 19_500, text: "On Monday morning.")
        #expect(!EchoText.isEcho(short, of: [them]))
        let later = TranscriptLine(source: .mic, startMs: 40_000, endMs: 43_000, text: "They want an answer before then, on Thursday.")
        #expect(!EchoText.isEcho(later, of: [them]))
    }
}
