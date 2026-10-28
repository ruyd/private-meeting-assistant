import Foundation

/// Reads meetings from one linked account. Only reads: nothing is created or changed there.
protocol MeetingService: Sendable {
    /// The signed-in person's email.
    func accountEmail(_ api: APIClient) async throws -> String?
    /// Timed meetings between the two dates, soonest first.
    func meetings(_ api: APIClient, from: Date, to: Date, me: String?) async throws -> [MeetingDetails]
    /// A meeting the calendar window didn't have, straight from the service; nil if it isn't this
    /// service's or can't be found.
    func lookup(_ link: MeetingLink, _ api: APIClient, me: String?) async throws -> MeetingDetails?
    /// Fills in what the list leaves out (Zoom's list has no invitees).
    func complete(_ meeting: MeetingDetails, _ api: APIClient, me: String?) async throws -> MeetingDetails
}

extension MeetingService {
    func complete(_ meeting: MeetingDetails, _ api: APIClient, me: String?) async throws -> MeetingDetails { meeting }

    /// The meeting's join link: the one the service gives, else the first Meet, Zoom or Teams link in
    /// the event's location or description (a Zoom link in a Google Calendar event, say).
    static func joinLink(_ uri: String?, orIn texts: [String?]) -> (link: MeetingLink, url: URL)? {
        if let uri, let url = URL(string: uri), let link = MeetingLink.parse(uri) { return (link, url) }
        return MeetingLink.find(in: texts.compactMap { $0 }.joined(separator: "\n"))
    }

    static func isMe(_ email: String?, _ me: String?) -> Bool {
        guard let email, let me else { return false }
        return email.caseInsensitiveCompare(me) == .orderedSame
    }
}

/// Authorized GETs against one service's API.
struct APIClient: Sendable {
    let base: URL
    /// Returns a valid access token, refreshing it if needed; `force` refreshes even if it looks valid.
    let token: @Sendable (_ force: Bool) async throws -> String

    struct Failure: LocalizedError {
        let status: Int
        let body: String
        var errorDescription: String? {
            switch status {
            case 401: "The account needs to be linked again (\(status))."
            case 403: "The account doesn't allow this (\(status)). Check the app's permissions. \(body.prefix(200))"
            default: "The service returned \(status): \(body.prefix(300))"
            }
        }
    }

    func get(_ path: String, query: [String: String] = [:], headers: [String: String] = [:]) async throws -> Data {
        var components = URLComponents(url: base.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            components.percentEncodedQuery = OAuthClient.formEncode(query)
        }
        var request = URLRequest(url: components.url!)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }

        for attempt in 0..<2 {
            request.setValue("Bearer \(try await token(attempt > 0))", forHTTPHeaderField: "Authorization")
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401, attempt == 0 { continue }
            guard (200..<300).contains(status) else { throw Failure(status: status, body: String(decoding: data, as: UTF8.self)) }
            return data
        }
        throw Failure(status: 401, body: "")
    }

    func json<T: Decodable>(_ type: T.Type, _ path: String, query: [String: String] = [:], headers: [String: String] = [:]) async throws -> T {
        try JSONDecoder().decode(type, from: await get(path, query: query, headers: headers))
    }
}

private let isoDate = Date.ISO8601FormatStyle(includingFractionalSeconds: false)
private let isoFractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

/// "2026-10-28T14:00:00Z", "…+01:00", or with fractions of a second.
func parseISODate(_ text: String?) -> Date? {
    guard let text else { return nil }
    return (try? Date(text, strategy: isoDate)) ?? (try? Date(text, strategy: isoFractional))
}

// MARK: - Google Calendar

struct GoogleCalendarService: MeetingService {
    static let base = URL(string: "https://www.googleapis.com")!

    func accountEmail(_ api: APIClient) async throws -> String? {
        struct Info: Decodable { let email: String? }
        return try await api.json(Info.self, "oauth2/v3/userinfo").email
    }

    func meetings(_ api: APIClient, from: Date, to: Date, me: String?) async throws -> [MeetingDetails] {
        let data = try await api.get("calendar/v3/calendars/primary/events", query: [
            "timeMin": from.formatted(isoDate),
            "timeMax": to.formatted(isoDate),
            "singleEvents": "true",
            "orderBy": "startTime",
            "maxResults": "250",
        ])
        return try Self.parse(data, me: me)
    }

    func lookup(_ link: MeetingLink, _ api: APIClient, me: String?) async throws -> MeetingDetails? {
        // Meet has no API from a code to the event; the calendar window search covers it.
        nil
    }

    struct Events: Decodable {
        struct Event: Decodable {
            struct When: Decodable { let dateTime: String?; let date: String? }
            struct Person: Decodable {
                let email: String?
                let displayName: String?
                let organizer: Bool?
                /// Google's "self": this attendee is the signed-in person.
                let isSelf: Bool?
                let optional: Bool?
                let resource: Bool?
                let responseStatus: String?

                enum CodingKeys: String, CodingKey {
                    case email, displayName, organizer, isSelf = "self", optional, resource, responseStatus
                }
            }
            struct Conference: Decodable {
                struct EntryPoint: Decodable { let entryPointType: String?; let uri: String? }
                let entryPoints: [EntryPoint]?
            }
            let id: String
            let status: String?
            let summary: String?
            let start: When?
            let end: When?
            let hangoutLink: String?
            let conferenceData: Conference?
            let location: String?
            let description: String?
            let organizer: Person?
            let attendees: [Person]?
        }
        let items: [Event]?
    }

    static func parse(_ data: Data, me: String?) throws -> [MeetingDetails] {
        let events = try JSONDecoder().decode(Events.self, from: data).items ?? []
        return events.compactMap { details($0, me: me) }
    }

    private static func details(_ event: Events.Event, me: String?) -> MeetingDetails? {
        // All-day events have only a date; they're not meetings to record.
        guard event.status != "cancelled", let start = parseISODate(event.start?.dateTime) else { return nil }

        let video = event.conferenceData?.entryPoints?.first { $0.entryPointType == "video" }
        let found = joinLink(video?.uri ?? event.hangoutLink, orIn: [event.location, event.description])

        let attendees = (event.attendees ?? []).filter { $0.resource != true }
        var people: [MeetingParticipant] = attendees.map { participant($0, me: me) }
        if let organizer = event.organizer, !people.contains(where: { $0.role == .organizer }) {
            var p = participant(organizer, me: me)
            p.role = .organizer
            p.response = .accepted
            people.insert(p, at: 0)
        }
        let title: String = event.summary?.nilIfBlank ?? "Untitled event"
        return MeetingDetails(
            provider: .google, externalID: event.id, title: title,
            start: start, end: parseISODate(event.end?.dateTime),
            platform: found?.link.platform, joinURL: found?.url, participants: people
        )
    }

    private static func participant(_ p: Events.Event.Person, me: String?) -> MeetingParticipant {
        let role: MeetingParticipant.Role = p.organizer == true ? .organizer : (p.optional == true ? .optional : .required)
        let mine: Bool = p.isSelf == true || isMe(p.email, me)
        return MeetingParticipant(name: p.displayName, email: p.email, role: role, response: response(p.responseStatus), isMe: mine)
    }

    private static func response(_ status: String?) -> MeetingParticipant.Response {
        switch status {
        case "accepted": .accepted
        case "tentative": .tentative
        case "declined": .declined
        default: .none
        }
    }
}

// MARK: - Microsoft Graph (Outlook calendar, Teams)

struct MicrosoftGraphService: MeetingService {
    static let base = URL(string: "https://graph.microsoft.com/v1.0")!

    func accountEmail(_ api: APIClient) async throws -> String? {
        struct Me: Decodable { let mail: String?; let userPrincipalName: String? }
        let me = try await api.json(Me.self, "me")
        return me.mail ?? me.userPrincipalName
    }

    func meetings(_ api: APIClient, from: Date, to: Date, me: String?) async throws -> [MeetingDetails] {
        let data = try await api.get("me/calendarView", query: [
            "startDateTime": from.formatted(isoDate),
            "endDateTime": to.formatted(isoDate),
            "$top": "250",
            "$orderby": "start/dateTime",
            "$select": "id,subject,start,end,isAllDay,isCancelled,organizer,attendees,onlineMeeting,location,bodyPreview",
        ], headers: ["Prefer": "outlook.timezone=\"UTC\""])
        return try Self.parseEvents(data, me: me)
    }

    func lookup(_ link: MeetingLink, _ api: APIClient, me: String?) async throws -> MeetingDetails? {
        let filter: String
        switch link {
        case .teams(let url): filter = "JoinWebUrl eq '\(url.absoluteString.replacingOccurrences(of: "'", with: "''"))'"
        case .numeric(let id): filter = "joinMeetingIdSettings/joinMeetingId eq '\(id)'"
        default: return nil
        }
        let data = try await api.get("me/onlineMeetings", query: ["$filter": filter])
        return try Self.parseOnlineMeetings(data, me: me).first
    }

    struct Address: Decodable { let name: String?; let address: String? }
    struct Person: Decodable { let emailAddress: Address? }

    struct Events: Decodable {
        struct Event: Decodable {
            struct When: Decodable { let dateTime: String }
            struct Attendee: Decodable {
                struct Status: Decodable { let response: String? }
                let type: String?
                let status: Status?
                let emailAddress: Address?
            }
            struct Online: Decodable { let joinUrl: String? }
            struct Location: Decodable { let displayName: String? }
            let id: String
            let subject: String?
            let start: When
            let end: When?
            let isAllDay: Bool?
            let isCancelled: Bool?
            let organizer: Person?
            let attendees: [Attendee]?
            let onlineMeeting: Online?
            let location: Location?
            let bodyPreview: String?
        }
        let value: [Event]
    }

    /// Graph gives times in the zone asked for (UTC) without a suffix: "2026-10-28T14:00:00.0000000".
    static func utcDate(_ text: String) -> Date? {
        let trimmed = String(text.prefix(19))
        return parseISODate(trimmed + "Z")
    }

    static func parseEvents(_ data: Data, me: String?) throws -> [MeetingDetails] {
        try JSONDecoder().decode(Events.self, from: data).value.compactMap { event -> MeetingDetails? in
            guard event.isCancelled != true, event.isAllDay != true, let start = utcDate(event.start.dateTime) else { return nil }
            let found = joinLink(event.onlineMeeting?.joinUrl, orIn: [event.location?.displayName, event.bodyPreview])

            let organizerEmail = event.organizer?.emailAddress?.address
            var people: [MeetingParticipant] = []
            if let organizer = event.organizer?.emailAddress {
                people.append(MeetingParticipant(
                    name: organizer.name, email: organizer.address, role: .organizer, response: .accepted,
                    isMe: isMe(organizer.address, me)
                ))
            }
            for a in event.attendees ?? [] where a.type != "resource" {
                guard let address = a.emailAddress, !isMe(address.address, organizerEmail) else { continue }
                people.append(MeetingParticipant(
                    name: address.name, email: address.address,
                    role: a.type == "optional" ? .optional : .required,
                    response: response(a.status?.response),
                    isMe: isMe(address.address, me)
                ))
            }
            return MeetingDetails(
                provider: .microsoft, externalID: event.id, title: event.subject?.nilIfBlank ?? "Untitled event",
                start: start, end: event.end.flatMap { utcDate($0.dateTime) },
                platform: found?.link.platform, joinURL: found?.url, participants: people
            )
        }
    }

    struct OnlineMeetings: Decodable {
        struct Meeting: Decodable {
            struct Participants: Decodable {
                struct Info: Decodable {
                    struct Identity: Decodable {
                        struct User: Decodable { let displayName: String? }
                        let user: User?
                    }
                    let upn: String?
                    let role: String?
                    let identity: Identity?
                }
                let organizer: Info?
                let attendees: [Info]?
            }
            let id: String
            let subject: String?
            let startDateTime: String?
            let endDateTime: String?
            let joinWebUrl: String?
            let participants: Participants?
        }
        let value: [Meeting]
    }

    static func parseOnlineMeetings(_ data: Data, me: String?) throws -> [MeetingDetails] {
        try JSONDecoder().decode(OnlineMeetings.self, from: data).value.compactMap { m -> MeetingDetails? in
            guard let start = parseISODate(m.startDateTime) else { return nil }
            var people: [MeetingParticipant] = []
            if let o = m.participants?.organizer {
                people.append(MeetingParticipant(name: o.identity?.user?.displayName, email: o.upn, role: .organizer, response: .accepted, isMe: isMe(o.upn, me)))
            }
            for a in m.participants?.attendees ?? [] {
                people.append(MeetingParticipant(name: a.identity?.user?.displayName, email: a.upn, role: .required, isMe: isMe(a.upn, me)))
            }
            return MeetingDetails(
                provider: .microsoft, externalID: m.id, title: m.subject?.nilIfBlank ?? "Teams meeting",
                start: start, end: parseISODate(m.endDateTime), platform: .teams,
                joinURL: m.joinWebUrl.flatMap { URL(string: $0) }, participants: people
            )
        }
    }

    private static func response(_ status: String?) -> MeetingParticipant.Response {
        switch status {
        case "accepted", "organizer": .accepted
        case "tentativelyAccepted": .tentative
        case "declined": .declined
        default: .none
        }
    }
}

// MARK: - Zoom

struct ZoomService: MeetingService {
    static let base = URL(string: "https://api.zoom.us/v2")!

    func accountEmail(_ api: APIClient) async throws -> String? {
        struct User: Decodable { let email: String? }
        return try await api.json(User.self, "users/me").email
    }

    func meetings(_ api: APIClient, from: Date, to: Date, me: String?) async throws -> [MeetingDetails] {
        let data = try await api.get("users/me/meetings", query: ["type": "upcoming", "page_size": "100"])
        return try Self.parseList(data, me: me).filter { $0.start >= from && $0.start <= to }
    }

    func lookup(_ link: MeetingLink, _ api: APIClient, me: String?) async throws -> MeetingDetails? {
        switch link {
        case .zoom(let id), .numeric(let id):
            do {
                return try Self.parseMeeting(await api.get("meetings/\(id)"), me: me)
            } catch let error as APIClient.Failure where error.status == 404 || error.status == 400 {
                return nil
            }
        default:
            return nil
        }
    }

    func complete(_ meeting: MeetingDetails, _ api: APIClient, me: String?) async throws -> MeetingDetails {
        guard let full = try await lookup(.zoom(id: meeting.externalID), api, me: me) else { return meeting }
        // Keep the occurrence's time from the list; a recurring meeting's details give the series.
        var merged = full
        merged.start = meeting.start
        merged.end = meeting.end
        return merged
    }

    struct List: Decodable {
        let meetings: [Item]?
    }

    struct Item: Decodable {
        struct Settings: Decodable {
            struct Invitee: Decodable { let email: String? }
            let meeting_invitees: [Invitee]?
            let alternative_hosts: String?
        }
        let id: Int64
        let topic: String?
        let start_time: String?
        let duration: Int?
        let join_url: String?
        let host_email: String?
        let settings: Settings?
    }

    static func parseList(_ data: Data, me: String?) throws -> [MeetingDetails] {
        try JSONDecoder().decode(List.self, from: data).meetings?.compactMap { details($0, me: me) } ?? []
    }

    static func parseMeeting(_ data: Data, me: String?) throws -> MeetingDetails? {
        details(try JSONDecoder().decode(Item.self, from: data), me: me)
    }

    private static func details(_ item: Item, me: String?) -> MeetingDetails? {
        // Recurring meetings with no fixed time have no start.
        guard let start = parseISODate(item.start_time) else { return nil }
        var people: [MeetingParticipant] = []
        if let host = item.host_email {
            people.append(MeetingParticipant(email: host, role: .organizer, response: .accepted, isMe: isMe(host, me)))
        }
        let alternates = (item.settings?.alternative_hosts ?? "").split(whereSeparator: { $0 == ";" || $0 == "," })
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let invitees = (item.settings?.meeting_invitees ?? []).compactMap(\.email) + alternates
        for email in invitees where !email.isEmpty && !people.contains(where: { isMe($0.email, email) }) {
            people.append(MeetingParticipant(email: email, isMe: isMe(email, me)))
        }
        return MeetingDetails(
            provider: .zoom, externalID: String(item.id), title: item.topic?.nilIfBlank ?? "Zoom meeting",
            start: start, end: item.duration.map { start.addingTimeInterval(TimeInterval($0 * 60)) },
            platform: .zoom, joinURL: item.join_url.flatMap { URL(string: $0) }, participants: people
        )
    }
}
