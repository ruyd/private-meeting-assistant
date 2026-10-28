import Foundation

/// Writes a meeting's summary, decisions and action items with a local model in Ollama. Long
/// transcripts are summarized in parts first, and the notes merged (ported from the prototype's
/// src-tauri/src/llm/ollama.rs).
struct Summarizer {
    let baseURL: URL
    let model: String

    /// Characters of transcript per part; keeps prompts well inside the context window.
    static let chunkCharacters = 24_000
    static let contextTokens = 16_384
    static let timeout: TimeInterval = 5 * 60

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

    enum Failure: LocalizedError {
        case emptyTranscript
        case unreachable(String)
        case tooSlow
        case server(Int, String)
        case badOutput(String)

        var errorDescription: String? {
            switch self {
            case .emptyTranscript: "There's no transcript to summarize."
            case .unreachable(let why): "Ollama isn't reachable: \(why)"
            case .tooSlow: "The model took longer than 5 minutes. Try a smaller model in Settings."
            case .server(let code, let body): "Ollama returned \(code): \(body)"
            case .badOutput(let raw): "The model didn't return a usable summary: \(raw.prefix(200))"
            }
        }
    }

    /// `participants` (from the linked calendar) lets the model name who "Them" might be and give
    /// action items real owners.
    func summarize(_ segments: [Segment], participants: [MeetingParticipant] = []) async throws -> MeetingSummary {
        let speakerNote = Self.speakerNote + Self.participantsNote(participants)
        let transcript = Self.transcriptText(segments)
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Failure.emptyTranscript }

        let chunks = Self.chunkLines(transcript, max: Self.chunkCharacters)
        let material: String
        if chunks.count == 1 {
            material = "Transcript:\n\(transcript)"
        } else {
            var notes: [String] = []
            for (i, chunk) in chunks.enumerated() {
                notes.append(try await chat("""
                    You are taking notes on part \(i + 1) of \(chunks.count) of a meeting transcript. \(speakerNote)
                    Write concise bullet-point notes covering topics discussed, any decisions made, and any tasks or commitments (with who owns them). Keep timestamps for key moments.

                    Transcript part:
                    \(chunk)
                    """, format: nil))
            }
            material = "Notes from consecutive parts of the meeting:\n\n" + notes.joined(separator: "\n\n---\n\n")
        }

        let raw = try await chat("""
            You are a meeting assistant. \(speakerNote)
            Produce JSON with:
            - "summary": a short paragraph (3-6 sentences) of what the meeting was about and its outcome
            - "decisions": decisions that were actually agreed (empty list if none)
            - "actionItems": concrete follow-up tasks, each with "text" and "owner" ("Me", a name mentioned in the meeting, or "" if unclear). Keep the owner out of "text". Only include tasks someone committed to or was asked to do.
            Use only information present in the material. Do not invent names.

            \(material)
            """, format: Self.schema, unload: true)
        return try Self.parse(raw)
    }

    // MARK: Ollama

    private func chat(_ prompt: String, format: [String: Any]?, unload: Bool = false) async throws -> String {
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
        segments.map { "[\(TranscriptExport.timestamp($0.startMs))] \($0.source.speaker): \($0.text)" }.joined(separator: "\n")
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
