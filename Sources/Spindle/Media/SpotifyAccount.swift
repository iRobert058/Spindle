import AppKit
import CryptoKit
import Foundation
import Security

/// The user's Spotify login, for reading their library through the Web API.
///
/// Spotify's AppleScript dictionary can play a URI but cannot list a single
/// playlist, so browsing needs the Web API, and the Web API needs a login.
/// This uses the Authorization Code flow with PKCE: no client secret exists
/// anywhere, and the only thing the user brings is the Client ID of an app they
/// register themselves at developer.spotify.com.
///
/// The refresh token lives in the Keychain. The access token is only ever held
/// in memory and refreshed on demand.
@MainActor
final class SpotifyAccount: ObservableObject {

    enum State: Equatable {
        case disconnected
        case connecting
        case connected
        case failed(String)
    }

    /// Fixed, because the redirect URI has to be registered on Spotify's side
    /// character for character. Spotify only accepts loopback redirects as an
    /// IP literal, never `localhost`.
    static let redirectPort: UInt16 = 43_821
    static let redirectURI = "http://127.0.0.1:\(redirectPort)/callback"
    static let dashboardURL = URL(string: "https://developer.spotify.com/dashboard")!
    /// Read-only, and nothing beyond what the menu lists.
    static let scopes = "playlist-read-private playlist-read-collaborative user-library-read"

    @Published var clientID: String {
        didSet {
            let trimmed = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed != clientID { clientID = trimmed; return }
            defaults.set(clientID, forKey: Key.clientID)
        }
    }

    @Published private(set) var state: State

    var isConnected: Bool { state == .connected }

    private let defaults: UserDefaults
    private let tokens: TokenStore
    private let session: URLSession
    private var accessToken: String?
    private var accessTokenExpiry: Date = .distantPast
    private var refreshTask: Task<String, Error>?
    private var connectTask: Task<Void, Never>?
    private var redirect: LoopbackRedirect?

    private enum Key {
        static let clientID = "spotify.clientID"
        /// Mirrors whether a refresh token was stored, so launching does not
        /// have to touch the Keychain just to draw the Settings window.
        static let connected = "spotify.connected"
    }

    init(
        defaults: UserDefaults = .standard,
        tokens: TokenStore = KeychainTokenStore(),
        session: URLSession = .shared
    ) {
        self.defaults = defaults
        self.tokens = tokens
        self.session = session
        let storedID = defaults.string(forKey: Key.clientID) ?? ""
        self.clientID = storedID
        self.state = defaults.bool(forKey: Key.connected) && !storedID.isEmpty
            ? .connected : .disconnected
    }

    // MARK: - Connecting

    /// Opens Spotify's consent page in the browser and waits for it to come
    /// back to the loopback redirect.
    func connect() {
        guard !clientID.isEmpty else {
            state = .failed("Paste your app's Client ID first.")
            return
        }
        cancelConnect()
        state = .connecting

        let verifier = PKCE.makeVerifier()
        let stateToken = PKCE.makeVerifier(length: 32)
        let clientID = self.clientID
        let redirect = LoopbackRedirect(port: Self.redirectPort)
        self.redirect = redirect

        connectTask = Task { [weak self] in
            defer { redirect.stop() }
            do {
                try redirect.start(expectingState: stateToken)
                NSWorkspace.shared.open(Self.authorizeURL(
                    clientID: clientID,
                    challenge: PKCE.challenge(for: verifier),
                    state: stateToken
                ))
                let code = try await redirect.waitForCode(timeout: 300)
                guard let self else { return }
                try await self.exchange(code: code, verifier: verifier, clientID: clientID)
                self.state = .connected
            } catch is CancellationError {
                return
            } catch {
                self?.state = .failed(error.localizedDescription)
            }
        }
    }

    func cancelConnect() {
        connectTask?.cancel()
        connectTask = nil
        redirect?.stop()
        redirect = nil
        if state == .connecting { state = .disconnected }
    }

    func disconnect() {
        cancelConnect()
        refreshTask?.cancel()
        refreshTask = nil
        accessToken = nil
        accessTokenExpiry = .distantPast
        tokens.deleteRefreshToken()
        defaults.set(false, forKey: Key.connected)
        state = .disconnected
    }

    // MARK: - Tokens

    /// A token good for at least another minute, refreshing if it has to.
    /// Concurrent callers share one refresh rather than racing to rotate the
    /// refresh token.
    func validAccessToken() async throws -> String {
        if let accessToken, accessTokenExpiry.timeIntervalSinceNow > 60 {
            return accessToken
        }
        if let refreshTask { return try await refreshTask.value }
        let task = Task { try await self.refresh() }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }

    /// The API refused the token we held; forget it so the next call refreshes.
    func invalidateAccessToken() {
        accessToken = nil
        accessTokenExpiry = .distantPast
    }

    private func refresh() async throws -> String {
        guard isConnected, !clientID.isEmpty,
              let refreshToken = tokens.loadRefreshToken() else {
            throw SpotifyError.notConnected
        }
        do {
            return try await requestToken([
                ("grant_type", "refresh_token"),
                ("refresh_token", refreshToken),
                ("client_id", clientID)
            ])
        } catch SpotifyError.rejected {
            // Revoked from Spotify's side, or the Client ID was changed. Asking
            // again is the only way forward.
            disconnect()
            state = .failed("Spotify signed Spindle out. Connect again.")
            throw SpotifyError.notConnected
        }
    }

    private func exchange(code: String, verifier: String, clientID: String) async throws {
        _ = try await requestToken([
            ("grant_type", "authorization_code"),
            ("code", code),
            ("redirect_uri", Self.redirectURI),
            ("client_id", clientID),
            ("code_verifier", verifier)
        ])
        defaults.set(true, forKey: Key.connected)
    }

    private func requestToken(_ form: [(String, String)]) async throws -> String {
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(FormEncoding.encode(form).utf8)

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            if status == 400 || status == 401 { throw SpotifyError.rejected }
            throw SpotifyError.http(status)
        }
        let token = try JSONDecoder().decode(TokenResponse.self, from: data)
        accessToken = token.accessToken
        accessTokenExpiry = Date().addingTimeInterval(TimeInterval(token.expiresIn))
        // Spotify may rotate the refresh token; when it does, the old one is dead.
        if let rotated = token.refreshToken {
            guard tokens.saveRefreshToken(rotated) else { throw SpotifyError.keychain }
        }
        return token.accessToken
    }

    private static func authorizeURL(clientID: String, challenge: String, state: String) -> URL {
        var components = URLComponents(string: "https://accounts.spotify.com/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "state", value: state)
        ]
        return components.url!
    }

    private struct TokenResponse: Decodable {
        let accessToken: String
        let expiresIn: Int
        let refreshToken: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case expiresIn = "expires_in"
            case refreshToken = "refresh_token"
        }
    }
}

enum SpotifyError: LocalizedError, Equatable {
    case notConnected
    case rejected
    case http(Int)
    case keychain
    case redirectFailed(String)
    case timedOut

    var errorDescription: String? {
        switch self {
        case .notConnected: return "Spotify is not connected."
        case .rejected: return "Spotify refused the login. Check the Client ID and Redirect URI."
        case .http(let status): return "Spotify answered with HTTP \(status)."
        case .keychain: return "Could not save the Spotify login to the Keychain."
        case .redirectFailed(let detail): return detail
        case .timedOut: return "Timed out waiting for the browser. Try again."
        }
    }
}

// MARK: - PKCE

enum PKCE {
    private static let unreserved = Array(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    /// RFC 7636 wants 43–128 characters from the unreserved set.
    static func makeVerifier(length: Int = 64) -> String {
        var bytes = [UInt8](repeating: 0, count: length)
        let status = SecRandomCopyBytes(kSecRandomDefault, length, &bytes)
        precondition(status == errSecSuccess, "system random generator failed")
        return String(bytes.map { unreserved[Int($0) % unreserved.count] })
    }

    static func challenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

enum FormEncoding {
    private static let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))

    static func encode(_ pairs: [(String, String)]) -> String {
        pairs.map { key, value in
            "\(escape(key))=\(escape(value))"
        }.joined(separator: "&")
    }

    private static func escape(_ string: String) -> String {
        string.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }
}

// MARK: - Keychain

protocol TokenStore {
    func loadRefreshToken() -> String?
    @discardableResult func saveRefreshToken(_ token: String) -> Bool
    func deleteRefreshToken()
}

struct KeychainTokenStore: TokenStore {
    private let service = "nl.jopmors.Spindle.spotify"
    private let account = "refresh-token"

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    func loadRefreshToken() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func saveRefreshToken(_ token: String) -> Bool {
        let data = Data(token.utf8)
        let update = [kSecValueData as String: data]
        let status = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var insert = baseQuery
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
    }

    func deleteRefreshToken() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}
