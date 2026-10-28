/// A last safety net against speaker echo: a "Me" line that's mostly the words of a "Them" line from the
/// same moment is the far end leaking through the mic, not you. Audio-level echo handling catches
/// nearly all of it; this catches what slips through while the echo canceller recovers from loud
/// double talk.
enum EchoText {
    /// Share of the "Me" line's words that must appear in overlapping "Them" lines.
    static let threshold = 0.6
    /// "Them" lines starting this long before the "Me" line (echo lags, lines split differently) or
    /// shortly after it count as overlapping.
    static let windowBeforeMs = 4_000
    static let windowAfterMs = 1_500
    /// Very short lines ("Yes.", "Okay.") are too common to judge.
    static let minWords = 4

    static func isEcho(_ me: TranscriptLine, of lines: [TranscriptLine]) -> Bool {
        guard me.source == .mic else { return false }
        let words = Self.words(me.text)
        guard words.count >= minWords else { return false }
        let them = Set(lines.filter { line in
            line.source == .system
                && line.startMs >= me.startMs - windowBeforeMs
                && line.startMs <= me.endMs + windowAfterMs
        }.flatMap { Self.words($0.text) })
        guard !them.isEmpty else { return false }
        let shared = words.filter(them.contains).count
        return Double(shared) / Double(words.count) >= threshold
    }

    static func words(_ text: String) -> [String] {
        text.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }
}
