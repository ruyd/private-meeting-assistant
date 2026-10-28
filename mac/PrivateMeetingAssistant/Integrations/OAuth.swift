import AppKit
import CryptoKit
import Foundation
import Network
import Synchronization

/// Signing in to Google, Microsoft or Zoom with OAuth 2 (authorization code with PKCE): the sign-in
/// page opens in the default browser, which comes back to a one-time listener on this Mac's loopback
/// address. Each person or company registers their own OAuth app and enters its client ID in
/// Settings › Accounts, so nothing goes through a server of ours.
struct OAuthClient: Sendable {
    let provider: MeetingProvider
    let clientID: String
    /// Google's desktop apps and some Zoom apps need one; it isn't secret in a desktop app, and PKCE
    /// is what protects the sign-in.
    let clientSecret: String?

    var authorizeURL: URL {
        switch provider {
        case .google: URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        case .microsoft: URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/authorize")!
        case .zoom: URL(string: "https://zoom.us/oauth/authorize")!
        }
    }

    var tokenURL: URL {
        switch provider {
        case .google: URL(string: "https://oauth2.googleapis.com/token")!
        case .microsoft: URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/token")!
        case .zoom: URL(string: "https://zoom.us/oauth/token")!
        }
    }

    /// Read-only access to calendar events and meetings, nothing else.
    var scopes: [String] {
        switch provider {
        case .google: ["openid", "email", "profile", "https://www.googleapis.com/auth/calendar.events.readonly"]
        case .microsoft: ["offline_access", "User.Read", "Calendars.Read", "OnlineMeetings.Read"]
        // Zoom takes the scopes chosen when the app was registered.
        case .zoom: []
        }
    }

    /// Microsoft only accepts "localhost" for loopback redirects registered in the portal; Google and
    /// Zoom want the IP address.
    var redirectHost: String { provider == .microsoft ? "localhost" : "127.0.0.1" }

    /// What to register as the redirect URI. The port changes each time; all three ignore it for
    /// loopback addresses.
    var registeredRedirectURI: String { "http://\(redirectHost)/callback" }

    enum Failure: LocalizedError {
        case missingClientID
        case cancelled
        case denied(String)
        case stateMismatch
        case token(Int, String)

        var errorDescription: String? {
            switch self {
            case .missingClientID: "Enter the client ID of your OAuth app first."
            case .cancelled: "Sign-in didn't finish."
            case .denied(let why): "Sign-in was refused: \(why)"
            case .stateMismatch: "The sign-in response didn't match this request. Try again."
            case .token(let code, let body): "The sign-in server returned \(code): \(body.prefix(300))"
            }
        }
    }

    /// Opens the sign-in page in the browser and waits (up to 5 minutes) for the person to finish.
    func signIn() async throws -> OAuthTokens {
        guard !clientID.isEmpty else { throw Failure.missingClientID }
        let verifier = Self.randomString()
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded
        let state = Self.randomString()

        let listener = try await LoopbackListener.start()
        defer { listener.cancel() }
        let redirectURI = "http://\(redirectHost):\(listener.port)/callback"

        var components = URLComponents(url: authorizeURL, resolvingAgainstBaseURL: false)!
        var items = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        if !scopes.isEmpty { items.append(URLQueryItem(name: "scope", value: scopes.joined(separator: " "))) }
        // Google only returns a refresh token when asked for offline access with consent.
        if provider == .google {
            items += [URLQueryItem(name: "access_type", value: "offline"), URLQueryItem(name: "prompt", value: "consent")]
        }
        if provider == .microsoft { items.append(URLQueryItem(name: "prompt", value: "select_account")) }
        components.queryItems = items
        await MainActor.run { _ = NSWorkspace.shared.open(components.url!) }

        let query = try await listener.callback(timeout: .seconds(300))
        if let error = query["error"] { throw Failure.denied(query["error_description"] ?? error) }
        guard query["state"] == state else { throw Failure.stateMismatch }
        guard let code = query["code"] else { throw Failure.cancelled }

        return try await requestTokens([
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
            "code_verifier": verifier,
        ], previous: nil)
    }

    /// A fresh access token from the refresh token.
    func refresh(_ tokens: OAuthTokens) async throws -> OAuthTokens {
        guard let refreshToken = tokens.refreshToken else { throw Failure.cancelled }
        var form = ["grant_type": "refresh_token", "refresh_token": refreshToken]
        if provider == .microsoft { form["scope"] = scopes.joined(separator: " ") }
        return try await requestTokens(form, previous: tokens)
    }

    private func requestTokens(_ form: [String: String], previous: OAuthTokens?) async throws -> OAuthTokens {
        var form = form
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if provider == .zoom, let clientSecret {
            // Zoom wants a confidential client's credentials as Basic auth.
            let basic = Data("\(clientID):\(clientSecret)".utf8).base64EncodedString()
            request.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")
        } else {
            form["client_id"] = clientID
            if let clientSecret { form["client_secret"] = clientSecret }
        }
        request.httpBody = Data(Self.formEncode(form).utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw Failure.token(status, String(decoding: data, as: UTF8.self)) }

        struct Body: Decodable {
            let access_token: String
            let refresh_token: String?
            let expires_in: Double?
        }
        let body = try JSONDecoder().decode(Body.self, from: data)
        return OAuthTokens(
            accessToken: body.access_token,
            // A refresh may not return a new refresh token; keep the old one.
            refreshToken: body.refresh_token ?? previous?.refreshToken,
            expiresAt: Date().addingTimeInterval(body.expires_in ?? 3600),
            account: previous?.account
        )
    }

    static func formEncode(_ form: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return form.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&")
    }

    private static func randomString() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncoded
    }
}

/// A linked account's tokens, kept in the Keychain.
struct OAuthTokens: Codable, Sendable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date
    /// The signed-in person's email, shown in Settings and used to tell "Me" apart among participants.
    var account: String?

    var isExpired: Bool { expiresAt.timeIntervalSinceNow < 60 }
}

extension Data {
    var base64URLEncoded: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// A one-shot HTTP listener on the loopback address that catches the browser's redirect after
/// sign-in. It only binds to 127.0.0.1 (and ::1, for browsers that resolve "localhost" to it), so
/// nothing outside this Mac can reach it.
private final class LoopbackListener: @unchecked Sendable {
    private let listeners: [NWListener]
    private let queue = DispatchQueue(label: "oauth.loopback")
    let port: UInt16
    private var continuation: CheckedContinuation<[String: String], Error>?
    private var result: Result<[String: String], Error>?

    private init(listeners: [NWListener], port: UInt16) {
        self.listeners = listeners
        self.port = port
    }

    static func start() async throws -> LoopbackListener {
        let v4 = try await ready(NWListener(using: parameters(host: "127.0.0.1", port: .any)))
        guard let port = v4.port else { throw OAuthClient.Failure.cancelled }
        var listeners = [v4]
        // Best effort: the same port on IPv6 may be taken.
        if let v6 = try? NWListener(using: parameters(host: "::1", port: port)),
           let v6 = try? await ready(v6) {
            listeners.append(v6)
        }
        let listener = LoopbackListener(listeners: listeners, port: port.rawValue)
        for l in listeners {
            l.newConnectionHandler = { [weak listener] connection in listener?.handle(connection) }
        }
        return listener
    }

    private static func parameters(host: String, port: NWEndpoint.Port) -> NWParameters {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: port)
        parameters.acceptLocalOnly = true
        return parameters
    }

    private static func ready(_ listener: NWListener) async throws -> NWListener {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let resumed = Mutex(false)
            listener.stateUpdateHandler = { state in
                let result: Result<Void, Error>
                switch state {
                case .ready: result = .success(())
                case .failed(let error): result = .failure(error)
                case .cancelled: result = .failure(OAuthClient.Failure.cancelled)
                default: return
                }
                guard resumed.withLock({ done in defer { done = true }; return !done }) else { return }
                continuation.resume(with: result)
            }
            listener.start(queue: DispatchQueue(label: "oauth.loopback.start"))
        }
        return listener
    }

    /// The redirect's query parameters.
    func callback(timeout: Duration) async throws -> [String: String] {
        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            self?.finish(.failure(OAuthClient.Failure.cancelled))
        }
        defer { timer.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    if let result = self.result {
                        continuation.resume(with: result)
                    } else {
                        self.continuation = continuation
                    }
                }
            }
        } onCancel: {
            self.finish(.failure(OAuthClient.Failure.cancelled))
        }
    }

    func cancel() {
        listeners.forEach { $0.cancel() }
    }

    private func finish(_ result: Result<[String: String], Error>) {
        queue.async {
            guard self.result == nil else { return }
            self.result = result
            self.continuation?.resume(with: result)
            self.continuation = nil
        }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            let request = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
            // "GET /callback?code=…&state=… HTTP/1.1"
            let target = request.split(separator: " ", maxSplits: 2).dropFirst().first.map(String.init) ?? ""
            let components = URLComponents(string: target)
            let isCallback = components?.path == "/callback"
            let body = isCallback
                ? "<html><body style=\"font: 15px -apple-system; padding: 3em\"><h2>You're signed in.</h2><p>You can close this tab and go back to Private Meeting Assistant.</p></body></html>"
                : "Not found"
            let response = "HTTP/1.1 \(isCallback ? "200 OK" : "404 Not Found")\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            guard isCallback else { return }
            var query: [String: String] = [:]
            for item in components?.queryItems ?? [] { query[item.name] = item.value ?? "" }
            self?.finish(.success(query))
        }
    }
}
