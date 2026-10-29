import Foundation
import FoundationModels

/// Writes a meeting's summary, decisions and action items with a model on this Mac: one in Ollama, or
/// Apple's on-device model (Apple Intelligence). Long transcripts are summarized in parts first, and
/// the notes merged (ported from the prototype's src-tauri/src/llm/ollama.rs).
struct Summarizer {
    enum Backend: Sendable {
        /// An Ollama server and the model to use on it.
        case ollama(URL, model: String)
        /// Apple's on-device model (`SystemLanguageModel`).
        case apple
    }

    let backend: Backend

    static let contextTokens = 16_384
    static let timeout: TimeInterval = 5 * 60

    /// Characters of transcript per part; keeps prompts well inside the context window. Apple's
    /// model has a 4,096-token window for the prompt and the answer together.
    var chunkCharacters: Int {
        switch backend {
        case .ollama: 24_000
        case .apple: 7_000
        }
    }

    /// When voices were told apart: each label is one person, named or numbered.
    private static let voicesNote = """
        Each speaker label is one person: a name, "Me" (the person who recorded the meeting), or "Participant N" for a voice that wasn't named. Refer to people by those labels.
        """

    private static let speakerNote = """
        "Me" is the person who recorded the meeting; "Them" is everyone heard through the computer's audio (possibly several people).
        """

    static func participantsNote(_ participants: [MeetingParticipant]) -> String {
        guard !participants.isEmpty else { return "" }
        let me = participants.first(where: \.isMe).map { " \"Me\" is \($0.displayName)." } ?? ""
        let others = participants.filter { !$0.isMe && $0.response != .declined }.map(\.displayName)
        let them = others.isEmpty ? "" : " Invited participants who may be among \"Them\": \(others.joined(separator: ", ")). Only attribute something to one of them by name if the transcript makes clear who said it."
        return me + them
    }

    /// Below this many words, spoken and typed together, there's nothing to summarize: given "Ah!",
    /// the model made up a whole meeting about a project launch.
    static let minimumWords = 12
    static let tooLittle = "Too little was said to summarize."

    /// Words with at least one letter or digit in them.
    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).filter { $0.contains { $0.isLetter || $0.isNumber } }.count
    }

    /// How the model is told to handle a meeting with little in it.
    private static let substanceNote = "If the material says little of substance, say so plainly in one sentence and leave decisions and action items empty. Never make up topics, projects, problems or tasks."

    enum Failure: LocalizedError {
        case emptyTranscript
        case unreachable(String)
        case tooSlow
        case server(Int, String)
        case badOutput(String)
        case apple(String)

        var errorDescription: String? {
            switch self {
            case .emptyTranscript: "There's no transcript to summarize."
            case .unreachable(let why): "Ollama isn't reachable: \(why)"
            case .tooSlow: "The model took longer than 5 minutes. Try a smaller model in Settings."
            case .server(let code, let body): "Ollama returned \(code): \(body)"
            case .badOutput(let raw): "The model didn't return a usable summary: \(raw.prefix(200))"
            case .apple(let why): why
            }
        }
    }

    /// `participants` (from the linked calendar) lets the model name who "Them" might be and give
    /// action items real owners.
    /// `notes` are what the recorder typed during or after the meeting: extra context, and often the
    /// points they cared about most.
    func summarize(_ segments: [Segment], participants: [MeetingParticipant] = [], notes: String = "") async throws -> MeetingSummary {
        let speakerNote = (segments.contains { $0.participant != nil } ? Self.voicesNote : Self.speakerNote)
            + Self.participantsNote(participants)
        let transcript = Self.transcriptText(segments)
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Failure.emptyTranscript }
        if segments.reduce(Self.wordCount(notes), { $0 + Self.wordCount($1.text) }) < Self.minimumWords {
            return MeetingSummary(summary: Self.tooLittle)
        }

        let chunks = Self.chunkLines(transcript, max: chunkCharacters)
        var material: String
        if chunks.count == 1 {
            material = "Transcript:\n\(transcript)"
        } else {
            var notes = try await takeNotes(chunks, of: "a meeting transcript", speakerNote: speakerNote)
            // A small context window can't take all the notes of a long meeting at once: condense
            // them in parts until they fit.
            while notes.joined(separator: "\n\n").count > chunkCharacters, notes.count > 1 {
                let groups = Self.chunkLines(notes.joined(separator: "\n\n"), max: chunkCharacters)
                guard groups.count < notes.count else { break }
                notes = try await takeNotes(groups, of: "notes on a meeting", speakerNote: speakerNote)
            }
            material = "Notes from consecutive parts of the meeting:\n\n" + notes.joined(separator: "\n\n---\n\n")
        }
        let typed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty {
            // Kept short so it never crowds out the meeting itself in a small context window.
            material += "\n\nNotes \"Me\" typed during the meeting (use them to weigh what mattered; don't repeat them verbatim):\n\(typed.prefix(2_000))"
        }

        if case .apple = backend {
            return try await Self.cleaned(appleSummary(material, speakerNote: speakerNote))
        }
        let raw = try await chat("""
            You are a meeting assistant. \(speakerNote)
            Produce JSON with:
            - "summary": a short paragraph (3-6 sentences) of what the meeting was about and its outcome
            - "decisions": decisions that were actually agreed (empty list if none)
            - "actionItems": concrete follow-up tasks, each with "text" and "owner" (the speaker label of the person who took it on or was asked to do it: "Me", a name, or "Participant N"; or "" if unclear). Keep the owner out of "text". Only include tasks someone committed to or was asked to do.
            Use only information present in the material. Do not invent names. \(Self.substanceNote)

            \(material)
            """, format: Self.schema, unload: true)
        return try Self.parse(raw)
    }

    private func takeNotes(_ parts: [String], of what: String, speakerNote: String) async throws -> [String] {
        var notes: [String] = []
        for (i, part) in parts.enumerated() {
            notes.append(try await chat("""
                You are taking notes on part \(i + 1) of \(parts.count) of \(what). \(speakerNote)
                Write concise bullet-point notes covering topics discussed, any decisions made, and any tasks or commitments (with who owns them). Keep timestamps for key moments.

                Part:
                \(part)
                """, format: nil))
        }
        return notes
    }

    // MARK: Apple's on-device model

    /// The summary's shape, for guided generation.
    @Generable
    struct GeneratedSummary {
        @Guide(description: "A short paragraph (up to 6 sentences) of what the meeting was about and its outcome, or one sentence saying little was discussed")
        var summary: String
        @Guide(description: "Decisions that were actually agreed; empty if none")
        var decisions: [String]
        @Guide(description: "Concrete follow-up tasks someone committed to or was asked to do")
        var actionItems: [GeneratedItem]
    }

    @Generable
    struct GeneratedItem {
        @Guide(description: "The task, without its owner")
        var text: String
        @Guide(description: "Who owns it: the speaker label of the person who took it on or was asked to do it (\"Me\", a name, or \"Participant N\"), or empty if unclear")
        var owner: String
    }

    private func appleSummary(_ material: String, speakerNote: String) async throws -> MeetingSummary {
        let session = LanguageModelSession(instructions: """
            You are a meeting assistant. \(speakerNote) Use only information present in the material. Do not invent names. \(Self.substanceNote)
            """)
        do {
            let response = try await session.respond(
                to: "Summarize this meeting: its summary, the decisions agreed, and the action items.\n\n\(material)",
                generating: GeneratedSummary.self,
                options: GenerationOptions(temperature: 0.2)
            )
            let g = response.content
            return MeetingSummary(
                summary: g.summary, decisions: g.decisions,
                actionItems: g.actionItems.map { MeetingSummary.ActionItem(text: $0.text, owner: $0.owner) }
            )
        } catch let error as LanguageModelSession.GenerationError {
            throw Failure.apple(Self.describe(error))
        }
    }

    private static func describe(_ error: LanguageModelSession.GenerationError) -> String {
        switch error {
        case .exceededContextWindowSize: "The meeting was too long for Apple's model in one go."
        case .guardrailViolation: "Apple's model declined to summarize this conversation."
        case .unsupportedLanguageOrLocale: "Apple's model doesn't support this meeting's language yet."
        case .assetsUnavailable: "Apple's model isn't ready yet. Try again in a few minutes."
        default: error.localizedDescription
        }
    }

    // MARK: Ollama

    private func chat(_ prompt: String, format: [String: Any]?, unload: Bool = false) async throws -> String {
        if case .apple = backend {
            let session = LanguageModelSession()
            do {
                return try await session.respond(to: prompt, options: GenerationOptions(temperature: 0.2)).content
            } catch let error as LanguageModelSession.GenerationError {
                throw Failure.apple(Self.describe(error))
            }
        }
        guard case .ollama(_, let model) = backend else { return "" }
        var body: [String: Any] = [
            "model": model,
            "stream": false,
            // Reasoning models are far slower and can loop under a JSON schema.
            "think": false,
            "messages": [["role": "user", "content": prompt]],
            "options": ["num_ctx": Self.contextTokens, "temperature": 0.2],
        ]
        if let format { body["format"] = format }
        // Free the model's memory once the summary is written, rather than after Ollama's 5 minutes.
        if unload { body["keep_alive"] = 0 }

        var (data, status) = try await send(body)
        if status == 400 {
            // Older servers and some models reject the `think` flag.
            body["think"] = nil
            (data, status) = try await send(body)
        }
        guard status == 200 else { throw Failure.server(status, String(decoding: data, as: UTF8.self)) }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = json["message"] as? [String: Any],
              let content = message["content"] as? String
        else { throw Failure.badOutput(String(decoding: data, as: UTF8.self)) }
        return content
    }

    private func send(_ body: [String: Any]) async throws -> (Data, Int) {
        guard case .ollama(let baseURL, _) = backend else { throw Failure.unreachable("no server") }
        var request = URLRequest(url: baseURL.appending(path: "api/chat"), timeoutInterval: Self.timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        } catch let error as URLError where error.code == .timedOut {
            throw Failure.tooSlow
        } catch let error as URLError {
            throw Failure.unreachable(error.localizedDescription)
        }
    }

    // MARK: Text

    static func transcriptText(_ segments: [Segment]) -> String {
        segments.map { "[\(TranscriptExport.timestamp($0.startMs))] \($0.speaker.isEmpty ? $0.source.speaker : $0.speaker): \($0.text)" }
            .joined(separator: "\n")
    }

    /// Splits on line boundaries into chunks of at most about `max` characters.
    static func chunkLines(_ text: String, max: Int) -> [String] {
        var chunks = [""]
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if !chunks[chunks.count - 1].isEmpty, chunks[chunks.count - 1].count + line.count + 1 > max {
                chunks.append("")
            }
            if !chunks[chunks.count - 1].isEmpty { chunks[chunks.count - 1] += "\n" }
            chunks[chunks.count - 1] += line
        }
        return chunks
    }

    /// The JSON shape the model must produce. A required string owner (rather than an optional one)
    /// keeps models from writing the owner into the task text.
    static var schema: [String: Any] { [
        "type": "object",
        "properties": [
            "summary": ["type": "string"],
            "decisions": ["type": "array", "items": ["type": "string"]],
            "actionItems": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": ["text": ["type": "string"], "owner": ["type": "string"]],
                    "required": ["text", "owner"],
                ],
            ],
        ],
        "required": ["summary", "decisions", "actionItems"],
    ] }

    /// Reads the model's JSON, tolerating prose or code fences around it.
    static func parse(_ raw: String) throws -> MeetingSummary {
        guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}") else { throw Failure.badOutput(raw) }
        var summary: MeetingSummary
        do {
            summary = try JSONDecoder().decode(MeetingSummary.self, from: Data(raw[start...end].utf8))
        } catch {
            throw Failure.badOutput(raw)
        }
        return cleaned(summary)
    }

    /// Drops empty action items and turns blank or "null" owners into none.
    static func cleaned(_ summary: MeetingSummary) -> MeetingSummary {
        var summary = summary
        summary.actionItems = summary.actionItems
            .filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { item in
                let owner = item.owner?.trimmingCharacters(in: .whitespaces)
                let unclear = owner == nil || owner!.isEmpty || owner!.lowercased() == "null"
                return MeetingSummary.ActionItem(text: item.text, owner: unclear ? nil : owner, done: false)
            }
        return summary
    }
}

extension MeetingSummary {
    /// Text for search: summary, decisions and action items.
    var searchableText: String {
        ([summary] + decisions + actionItems.map(\.text)).joined(separator: "\n")
    }
}
