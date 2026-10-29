import Foundation

/// A meeting's summary, decisions and action items, stored as JSON in `meetings.summary_json` (the
/// prototype's format, camelCase keys).
struct MeetingSummary: Codable, Hashable, Sendable {
    struct ActionItem: Codable, Hashable, Sendable {
        var text: String
        var owner: String?
        var done: Bool

        /// Who to show as the owner: none for a stand-in the model wrote when it couldn't tell
        /// ("Participant N", "Unknown"), as summaries written before owners were checked can have.
        var shownOwner: String? { owner.flatMap { MeetingSummary.isPlaceholderOwner($0) ? nil : $0 } }

        init(text: String, owner: String? = nil, done: Bool = false) {
            self.text = text
            self.owner = owner
            self.done = done
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            text = try c.decode(String.self, forKey: .text)
            owner = try c.decodeIfPresent(String.self, forKey: .owner)
            done = try c.decodeIfPresent(Bool.self, forKey: .done) ?? false
        }
    }

    /// Owners that only stand in for "no one in particular": the examples the prompt gives
    /// ("Participant N") and the usual ways of saying unknown.
    static func isPlaceholderOwner(_ owner: String) -> Bool {
        let o = owner.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return o.isEmpty || ["null", "none", "nil", "n/a", "na", "unknown", "unclear", "unassigned", "tbd", "-", "—",
                             "participant n", "participant x", "speaker", "someone", "a name", "name"].contains(o)
    }

    var summary: String
    var decisions: [String]
    var actionItems: [ActionItem]
    /// The engine that wrote it ("Apple Intelligence", "gemma3 in your Ollama"); nil for older ones.
    var writtenBy: String?

    init(summary: String, decisions: [String] = [], actionItems: [ActionItem] = []) {
        self.summary = summary
        self.decisions = decisions
        self.actionItems = actionItems
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        summary = try c.decode(String.self, forKey: .summary)
        decisions = try c.decodeIfPresent([String].self, forKey: .decisions) ?? []
        actionItems = try c.decodeIfPresent([ActionItem].self, forKey: .actionItems) ?? []
        writtenBy = try c.decodeIfPresent(String.self, forKey: .writtenBy)
    }
}
