import Foundation

/// Timestamps, clipboard text and file names for transcripts (the Markdown files are `MeetingFiles`).
enum TranscriptExport {
    static func timestamp(_ ms: Int) -> String {
        let s = ms / 1000
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
            : String(format: "%02d:%02d", s / 60, s % 60)
    }

    /// One line per transcript line, for the clipboard: "[01:05] Priya: Hello."
    static func plainText(_ lines: [(speaker: String, startMs: Int, text: String)]) -> String {
        lines.map { "[\(timestamp($0.startMs))] \($0.speaker): \($0.text)" }.joined(separator: "\n")
    }

    /// A file-name-safe version of a meeting title.
    static func fileName(_ title: String) -> String {
        let cleaned = String(title.map { $0.isLetter || $0.isNumber || " -_.".contains($0) ? $0 : "-" })
            .trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return cleaned.isEmpty ? "meeting" : String(cleaned.prefix(80))
    }
}
