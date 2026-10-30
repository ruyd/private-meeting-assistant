import Foundation
import Observation
import OSLog

private let log = Logger(subsystem: "dev.ruy.private-meeting-assistant", category: "accounts")

/// Linked Google, Microsoft and Zoom accounts, and the meetings they list: upcoming ones for the Record
/// page, and lookups by link or ID. Meeting details are fetched on this Mac with the person's own
/// tokens and kept with the recording; nothing about the recording is sent anywhere.
@MainActor @Observable
final class MeetingAccounts {
    static let shared = MeetingAccounts()

    /// Signed-in email per linked provider.
    private(set) var linked: [MeetingProvider: String] = [:]
    private(set) var upcoming: [MeetingDetails] = []
    private(set) var isRefreshing = false
    /// The last problem per provider, shown in Settings and on the Record page.
    private(set) var errors: [MeetingProvider: String] = [:]
    private(set) var signingIn: MeetingProvider?

    @ObservationIgnored private var tokens: [MeetingProvider: OAuthTokens] = [:]
    @ObservationIgnored private var refreshing: [MeetingProvider: Task<OAuthTokens, Error>] = [:]

    init() {
        for provider in MeetingProvider.allCases {
            if let saved = Keychain.decode(OAuthTokens.self, Self.tokensKey(provider)) {
                tokens[provider] = saved
                linked[provider] = saved.account ?? ""
            }
        }
    }

    // MARK: OAuth apps

    private static func tokensKey(_ provider: MeetingProvider) -> String { "tokens.\(provider.rawValue)" }

    /// The OAuth app the person signs in through: the one built into the app (Config/OAuth.xcconfig),
    /// unless an administrator set another in preferences (`oauthClientID.<provider>`,
    /// `oauthClientSecret.<provider>`, e.g. by MDM), for companies that register their own.
    nonisolated static func client(_ provider: MeetingProvider, bundle: Bundle = .main, defaults: UserDefaults = .standard) -> OAuthClient {
        let name = switch provider {
        case .google: "Google"
        case .microsoft: "Microsoft"
        case .zoom: "Zoom"
        }
        func value(_ defaultsKey: String, _ plistKey: String) -> String? {
            defaults.string(forKey: defaultsKey)?.nilIfBlank ?? (bundle.object(forInfoDictionaryKey: plistKey) as? String)?.nilIfBlank
        }
        let overridden = defaults.string(forKey: "oauthClientID.\(provider.rawValue)")?.nilIfBlank != nil
        let clientID = value("oauthClientID.\(provider.rawValue)", "PMA\(name)ClientID") ?? ""
        // A secret belongs to its client ID: never pair an administrator's ID with the built-in secret.
        let secret = overridden
            ? defaults.string(forKey: "oauthClientSecret.\(provider.rawValue)")?.nilIfBlank
            : (bundle.object(forInfoDictionaryKey: "PMA\(name)ClientSecret") as? String)?.nilIfBlank
        return OAuthClient(provider: provider, clientID: clientID, clientSecret: secret)
    }

    /// Providers this build (or the administrator) has an OAuth app for; the others aren't offered.
    /// None on the App Store: sign-in comes back to a loopback listener, which takes the
    /// `network.server` entitlement, and App Review refuses that for a feature the app doesn't show.
    var available: [MeetingProvider] {
        #if APPSTORE
        []
        #else
        MeetingProvider.allCases.filter { !Self.client($0).clientID.isEmpty }
        #endif
    }

    // MARK: Linking

    func link(_ provider: MeetingProvider) async {
        signingIn = provider
        errors[provider] = nil
        defer { signingIn = nil }
        do {
            var tokens = try await Self.client(provider).signIn()
            self.tokens[provider] = tokens
            tokens.account = try? await Self.service(provider).accountEmail(api(provider))
            self.tokens[provider] = tokens
            Keychain.encode(tokens, for: Self.tokensKey(provider))
            linked[provider] = tokens.account ?? ""
            await refreshUpcoming()
        } catch {
            log.error("linking \(provider.rawValue, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            errors[provider] = error.localizedDescription
        }
    }

    /// Forgets the tokens. (The access can also be revoked in the account's own security settings.)
    func unlink(_ provider: MeetingProvider) {
        tokens[provider] = nil
        linked[provider] = nil
        errors[provider] = nil
        Keychain.set(nil, for: Self.tokensKey(provider))
        upcoming.removeAll { $0.provider == provider }
    }

    // MARK: Meetings

    /// Meetings from an hour ago (one may be under way) to the end of tomorrow, from every linked
    /// account, with the same meeting seen in two places listed once.
    func refreshUpcoming(now: Date = Date()) async {
        guard !linked.isEmpty, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let from = now.addingTimeInterval(-3600)
        let to = Calendar.current.date(byAdding: .day, value: 2, to: Calendar.current.startOfDay(for: now)) ?? now.addingTimeInterval(2 * 86_400)
        var all: [MeetingDetails] = []
        for provider in MeetingProvider.allCases where linked[provider] != nil {
            do {
                all += try await Self.service(provider).meetings(api(provider), from: from, to: to, me: linked[provider]?.nilIfBlank)
                errors[provider] = nil
            } catch {
                log.error("\(provider.rawValue, privacy: .public) meetings failed: \(error.localizedDescription, privacy: .public)")
                errors[provider] = error.localizedDescription
            }
        }
        // Meetings that ended are no use for a new recording.
        upcoming = Self.merge(all).filter { ($0.end ?? $0.start.addingTimeInterval(3600)) > now }
    }

    /// One entry per meeting: a calendar event wins over Zoom's own listing (it has the invitees),
    /// keeping whichever knows more people.
    static func merge(_ meetings: [MeetingDetails]) -> [MeetingDetails] {
        var byKey: [String: MeetingDetails] = [:]
        var order: [String] = []
        for m in meetings {
            let key = m.dedupeKey
            if let existing = byKey[key] {
                let keepNew = (existing.provider == .zoom && m.provider != .zoom) || m.participants.count > existing.participants.count
                if keepNew { byKey[key] = m }
            } else {
                byKey[key] = m
                order.append(key)
            }
        }
        return order.compactMap { byKey[$0] }.sorted { $0.start < $1.start }
    }

    enum LookupFailure: LocalizedError {
        case notALink
        case noAccount(MeetingPlatform?)
        case notFound

        var errorDescription: String? {
            switch self {
            case .notALink: "That isn't a Meet, Zoom or Teams link or meeting ID."
            case .noAccount(let platform): "Sign in with \(platform.map(Self.provider).map(\.name) ?? "Google, Microsoft 365 or Zoom") in Settings › Accounts to look up \(platform?.name ?? "this") meeting."
            case .notFound: "No meeting with that link or ID was found in your linked accounts."
            }
        }

        static func provider(_ platform: MeetingPlatform) -> MeetingProvider {
            switch platform {
            case .googleMeet: .google
            case .zoom: .zoom
            case .teams: .microsoft
            }
        }
    }

    /// Finds a meeting from a pasted link or ID: first among the linked calendars' events (a week back
    /// to a month ahead), then by asking the service that runs it.
    func lookup(_ input: String) async throws -> MeetingDetails {
        guard let link = MeetingLink.parse(input) else { throw LookupFailure.notALink }
        guard !linked.isEmpty else { throw LookupFailure.noAccount(link.platform) }

        let now = Date()
        var lastError: Error?
        for provider in MeetingProvider.allCases where linked[provider] != nil {
            do {
                let events = try await Self.service(provider).meetings(
                    api(provider), from: now.addingTimeInterval(-7 * 86_400), to: now.addingTimeInterval(30 * 86_400),
                    me: linked[provider]?.nilIfBlank
                )
                if let match = Self.merge(events).first(where: { Self.matches($0, link) }) {
                    return try await complete(match)
                }
            } catch {
                lastError = error
            }
        }
        for provider in MeetingProvider.allCases where linked[provider] != nil {
            do {
                if let found = try await Self.service(provider).lookup(link, api(provider), me: linked[provider]?.nilIfBlank) {
                    return found
                }
            } catch {
                lastError = error
            }
        }
        if let lastError { throw lastError }
        if let platform = link.platform, linked[LookupFailure.provider(platform)] == nil {
            throw LookupFailure.noAccount(platform)
        }
        throw LookupFailure.notFound
    }

    static func matches(_ meeting: MeetingDetails, _ link: MeetingLink) -> Bool {
        guard let url = meeting.joinURL, let own = MeetingLink.parse(url.absoluteString) else { return false }
        if own == link { return true }
        if case .numeric(let id) = link, case .zoom(let zoomID) = own { return id == zoomID }
        if case .teams(let a) = link, case .teams(let b) = own {
            return a.absoluteString.removingPercentEncoding?.lowercased() == b.absoluteString.removingPercentEncoding?.lowercased()
        }
        return false
    }

    /// The meeting with everything its service knows (for Zoom, the invitees).
    func complete(_ meeting: MeetingDetails) async throws -> MeetingDetails {
        try await Self.service(meeting.provider).complete(meeting, api(meeting.provider), me: linked[meeting.provider]?.nilIfBlank)
    }

    // MARK: Plumbing

    private static func service(_ provider: MeetingProvider) -> any MeetingService {
        switch provider {
        case .google: GoogleCalendarService()
        case .microsoft: MicrosoftGraphService()
        case .zoom: ZoomService()
        }
    }

    private func api(_ provider: MeetingProvider) -> APIClient {
        let base: URL = switch provider {
        case .google: GoogleCalendarService.base
        case .microsoft: MicrosoftGraphService.base
        case .zoom: ZoomService.base
        }
        return APIClient(base: base) { [weak self] force in
            guard let self else { throw CancellationError() }
            return try await self.accessToken(provider, force: force)
        }
    }

    /// A valid access token, refreshed (once, however many requests ask) when it's about to expire.
    private func accessToken(_ provider: MeetingProvider, force: Bool) async throws -> String {
        guard let current = tokens[provider] else { throw LookupFailure.noAccount(nil) }
        if !force, !current.isExpired { return current.accessToken }
        if let running = refreshing[provider] { return try await running.value.accessToken }
        let client = Self.client(provider)
        let task = Task { try await client.refresh(current) }
        refreshing[provider] = task
        defer { refreshing[provider] = nil }
        do {
            let fresh = try await task.value
            tokens[provider] = fresh
            Keychain.encode(fresh, for: Self.tokensKey(provider))
            return fresh.accessToken
        } catch {
            errors[provider] = "Sign in again: \(error.localizedDescription)"
            throw error
        }
    }
}
