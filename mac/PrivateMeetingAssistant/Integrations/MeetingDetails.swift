import Foundation

/// The services meetings can be looked up in, once the person links an account.
enum MeetingProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case google, microsoft, zoom

    var id: String { rawValue }

    var name: String {
        switch self {
        case .google: "Google"
        case .microsoft: "Microsoft 365"
        case .zoom: "Zoom"
        }
    }

    /// What the account brings: a calendar, or Zoom's own list of meetings.
    var detail: String {
        switch self {
        case .google: "Google Calendar and Meet"
        case .microsoft: "Outlook calendar and Teams"
        case .zoom: "Zoom meetings"
        }
    }
}

/// The call app a meeting happens in, worked out from its join link.
enum MeetingPlatform: String, Codable, Sendable {
    case googleMeet, zoom, teams

    var name: String {
        switch self {
        case .googleMeet: "Google Meet"
        case .zoom: "Zoom"
        case .teams: "Teams"
        }
    }

    var symbol: String {
        switch self {
        case .googleMeet: "video"
        case .zoom: "video.circle"
        case .teams: "person.3"
        }
    }
}

/// Someone invited to a meeting, as the calendar or Zoom lists them.
struct MeetingParticipant: Codable, Hashable, Sendable, Identifiable {
    enum Role: String, Codable, Sendable { case organizer, required, optional }
    enum Response: String, Codable, Sendable { case accepted, tentative, declined, none }

    var name: String?
    var email: String?
    var role: Role = .required
    var response: Response = .none
    /// The person whose account the meeting came from, who is also "Me" in the transcript.
    var isMe = false

    var id: String { email?.lowercased() ?? name ?? "" }

    /// The name if known, else the email.
    var displayName: String { name?.nilIfBlank ?? email ?? "Unknown" }
}

/// What the calendar or meeting service says about a meeting: subject, schedule, join link and who's
/// invited. Kept with the recording so the transcript and summary know who "Them" were.
struct MeetingDetails: Codable, Hashable, Sendable, Identifiable {
    var provider: MeetingProvider
    /// The event or meeting ID in that service.
    var externalID: String
    var title: String
    var start: Date
    var end: Date?
    var platform: MeetingPlatform?
    var joinURL: URL?
    var participants: [MeetingParticipant] = []

    var id: String { "\(provider.rawValue):\(externalID)" }

    var organizer: MeetingParticipant? { participants.first { $0.role == .organizer } }

    /// Everyone but the recorder, organizer first, then by name.
    var others: [MeetingParticipant] {
        participants.filter { !$0.isMe }.sorted {
            ($0.role == .organizer ? 0 : 1, $0.displayName.lowercased()) < ($1.role == .organizer ? 0 : 1, $1.displayName.lowercased())
        }
    }

    /// A key that's the same for one meeting seen through two services (a Zoom link in a Google
    /// Calendar event, and the same meeting in Zoom's list).
    var dedupeKey: String {
        if let joinURL, let link = MeetingLink.parse(joinURL.absoluteString) { return link.key }
        return id
    }
}

/// A meeting link or ID someone pasted or a calendar event contains: which platform it's on and the
/// ID that service knows it by.
enum MeetingLink: Hashable, Sendable {
    /// A Meet code, "abc-defg-hij".
    case googleMeet(code: String)
    /// A Zoom meeting number, digits only.
    case zoom(id: String)
    /// A Teams join link ("https://teams.microsoft.com/l/meetup-join/…" or "…/meet/<id>").
    case teams(url: URL)
    /// Digits that could be a Zoom meeting number or a Teams meeting ID.
    case numeric(String)

    var platform: MeetingPlatform? {
        switch self {
        case .googleMeet: .googleMeet
        case .zoom: .zoom
        case .teams: .teams
        case .numeric: nil
        }
    }

    var key: String {
        switch self {
        case .googleMeet(let code): "meet:\(code)"
        case .zoom(let id), .numeric(let id): "num:\(id)"
        case .teams(let url): "teams:\(url.absoluteString.lowercased())"
        }
    }

    /// Reads a link or ID as typed: a Meet, Zoom or Teams URL, a Meet code, or a meeting number
    /// (spaces and dashes between digits allowed, as invitations print them).
    static func parse(_ input: String) -> MeetingLink? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        if let url = URL(string: text.contains("://") ? text : "https://\(text)"), let host = url.host()?.lowercased(),
           host.contains(".") {
            let path = url.pathComponents.filter { $0 != "/" }
            if host == "meet.google.com", let code = path.first.flatMap(meetCode) {
                return .googleMeet(code: code)
            }
            if host == "zoom.us" || host.hasSuffix(".zoom.us") || host.hasSuffix(".zoomgov.com") {
                // /j/<id>, /s/<id>, /w/<id>, /my/<name> (a personal link, no number to look up)
                if path.count >= 2, ["j", "s", "w", "wc"].contains(path[0]), let id = digits(path[1]) {
                    return .zoom(id: id)
                }
                return nil
            }
            if host == "teams.microsoft.com" || host == "teams.live.com" || host.hasSuffix(".teams.microsoft.com") {
                return .teams(url: url)
            }
        }
        if let code = meetCode(text) { return .googleMeet(code: code) }
        if let id = digits(text) { return .numeric(id) }
        return nil
    }

    /// The first Meet, Zoom or Teams link in free text: an event's location or description.
    static func find(in text: String) -> (link: MeetingLink, url: URL)? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        for match in detector.matches(in: text, range: range) {
            guard let url = match.url, let link = parse(url.absoluteString), link.platform != nil else { continue }
            return (link, url)
        }
        return nil
    }

    /// "abc-defg-hij" (or without dashes), lowercased.
    private static func meetCode(_ text: String) -> String? {
        let letters = text.lowercased().filter { $0 != "-" }
        guard letters.count == 10, letters.allSatisfy({ ("a"..."z").contains($0) }) else { return nil }
        let chars = Array(letters)
        return "\(String(chars[0..<3]))-\(String(chars[3..<7]))-\(String(chars[7..<10]))"
    }

    /// 9 to 15 digits, ignoring spaces and dashes; nil if anything else is there.
    private static func digits(_ text: String) -> String? {
        let stripped = text.filter { $0 != " " && $0 != "-" }
        guard (9...15).contains(stripped.count), stripped.allSatisfy(\.isASCII), stripped.allSatisfy(\.isNumber) else { return nil }
        return stripped
    }
}

extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
