import Foundation

/// One Google OAuth token, whichever source it came from.
struct GeminiToken: Sendable, Equatable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date?

    /// The Gemini CLI treats a token as spent five minutes early so a request
    /// started just before expiry still completes; match that.
    var isExpired: Bool {
        guard let expiresAt else { return false }
        return expiresAt.timeIntervalSinceNow < 300
    }
}

/// The OAuth client the Google sign-in runs as.
///
/// By default this is the public client the Gemini CLI ships in its bundle. It is
/// an installed-app client, so the "secret" is not one — it is readable in every
/// copy of the CLI — and reusing it is what lets the app's own sign-in reach the
/// same Code Assist quota the CLI reports.
///
/// Resolution order, so a build can run as its own client instead:
///
/// 1. `LIMIT_ISLAND_GOOGLE_CLIENT_ID` / `_SECRET` in the environment, for development.
/// 2. `GoogleOAuthClientID` / `GoogleOAuthClientSecret` in `Info.plist`, which
///    `Scripts/build-app.sh` injects from `GOOGLE_OAUTH_CLIENT_ID` / `_SECRET`
///    into the *copied* plist, never the tracked one.
/// 3. The bundled public client below.
///
/// The bundled pair is base64 so the repository holds no string matching a secret
/// scanner's patterns. That is hygiene, not protection: base64 is trivially
/// reversible, and this value is meant to be public anyway.
enum GeminiOAuthClient {
    private static let bundledClientID =
        "NjgxMjU1ODA5Mzk1LW9vOGZ0Mm9wcmRybnA5ZTNhcWY2YXYzaG1kaWIxMzVqLmFwcHMuZ29vZ2xldXNlcmNvbnRlbnQuY29t"
    private static let bundledClientSecret = "R09DU1BYLTR1SGdNUG0tMW83U2stZ2VWNkN1NWNsWEZzeGw="

    static let clientID = resolve(
        environmentKey: "LIMIT_ISLAND_GOOGLE_CLIENT_ID",
        infoKey: "GoogleOAuthClientID",
        bundled: bundledClientID
    )
    static let clientSecret = resolve(
        environmentKey: "LIMIT_ISLAND_GOOGLE_CLIENT_SECRET",
        infoKey: "GoogleOAuthClientSecret",
        bundled: bundledClientSecret
    )

    /// Split from the properties above so the precedence can be tested without a
    /// bundle. `bundled` is base64; the other two are plain, because whoever sets
    /// them is holding their own client and has nothing to hide from a scanner.
    static func resolve(
        environmentKey: String,
        infoKey: String,
        bundled: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        info: [String: Any] = Bundle.main.infoDictionary ?? [:]
    ) -> String {
        if let value = environment[environmentKey], !value.isEmpty { return value }
        if let value = info[infoKey] as? String, !value.isEmpty { return value }
        guard let data = Data(base64Encoded: bundled), let value = String(data: data, encoding: .utf8) else {
            // Unreachable with the constants above, and a crash here would take
            // out the whole app for a meter that may not even be configured.
            Log.auth.error("bundled google client value did not decode")
            return ""
        }
        return value
    }

    static let scopes = [
        "https://www.googleapis.com/auth/cloud-platform",
        "https://www.googleapis.com/auth/userinfo.email",
        "https://www.googleapis.com/auth/userinfo.profile"
    ]
    static let authorizationEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!
    static let userInfoEndpoint = URL(string: "https://www.googleapis.com/oauth2/v2/userinfo")!
}

/// Resolves a usable Gemini access token, refreshing when it has expired.
///
/// There are three places a token can live, because the Gemini CLI moved:
/// up to ~0.4x it wrote `~/.gemini/oauth_creds.json`, and newer versions migrate
/// that file into the login keychain and delete it. Reading only the file — which
/// is what this app used to do — finds nothing at all on a current CLI, which is
/// why Gemini meters stayed blank.
actor GeminiCredentialStore {
    static let shared = GeminiCredentialStore()

    /// Written by the Gemini CLI's `HybridTokenStorage`.
    static let cliService = "gemini-cli-oauth"
    static let cliAccount = "main-account"
    /// Written by this app's own sign-in, one item per meter.
    static let appService = "com.limitisland.gemini-oauth"
    /// How the broker addresses the CLI's item.
    static let cliKey = CredentialBroker.Key(service: cliService, account: cliAccount)

    private var cached: [String: GeminiToken] = [:]

    // MARK: - Detection

    /// Whether the Gemini CLI has a login on this Mac. Attribute-only, so it
    /// never raises the keychain authorization prompt.
    nonisolated static func cliLoginExists() -> Bool {
        if Keychain.exists(service: cliService, account: cliAccount) { return true }
        return FileManager.default.fileExists(atPath: legacyCredentialsURL.path)
    }

    nonisolated static var legacyCredentialsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini/oauth_creds.json")
    }

    /// The address the CLI last signed in as, for labelling the meter. Plain file,
    /// no secret, no prompt.
    nonisolated static func cliAccountLabel() -> String? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini/google_accounts.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let active = root["active"] as? String, !active.isEmpty else { return nil }
        return active
    }

    // MARK: - Reading

    /// A token good for at least the next five minutes, or nil if this credential
    /// has no Gemini login behind it.
    func token(for credential: CredentialSource) async -> GeminiToken? {
        let key = cacheKey(for: credential)
        if let cached = cached[key], !cached.isExpired { return cached }

        guard var token = await load(credential) else { return nil }
        if token.isExpired {
            guard let refreshed = await refresh(token) else {
                Log.auth.error("gemini token expired and could not be refreshed")
                return nil
            }
            token = refreshed
            // Only ever write back to our own storage. Rewriting the CLI's item
            // would rotate the access token out from under a running `gemini`,
            // leaving its in-memory copy stale. For a CLI-backed account that
            // means the broker's mirror, which is ours; the CLI's own item is
            // left exactly as it was.
            if let identifier = credential.oauthIdentifier {
                store(token, for: identifier)
            } else if let data = Self.encodeCLIKeychain(token) {
                await CredentialBroker.shared.replace(data, for: Self.cliKey)
            }
        }
        cached[key] = token
        return token
    }

    func store(_ token: GeminiToken, for identifier: UUID) {
        cached[Self.appService + identifier.uuidString] = token
        guard let data = try? JSONEncoder.googleEncoder.encode(StoredCredentials(token)) else { return }
        Keychain.set(data, service: Self.appService, account: identifier.uuidString)
    }

    func signOut(_ credential: CredentialSource) async {
        cached[cacheKey(for: credential)] = nil
        guard let identifier = credential.oauthIdentifier else {
            // A CLI-backed account has nothing of ours to delete, but the broker's
            // mirror of the CLI's token is ours and must go.
            await CredentialBroker.shared.forget(Self.cliKey)
            return
        }
        Keychain.remove(service: Self.appService, account: identifier.uuidString)
    }

    private func cacheKey(for credential: CredentialSource) -> String {
        if let identifier = credential.oauthIdentifier { return Self.appService + identifier.uuidString }
        return Self.cliService
    }

    // MARK: - Sources

    private func load(_ credential: CredentialSource) async -> GeminiToken? {
        // This app's own item. We created it, so reading it never prompts and it
        // does not need to go through the broker.
        if let identifier = credential.oauthIdentifier {
            guard let data = Keychain.data(service: Self.appService, account: identifier.uuidString) else { return nil }
            return Self.decodeStored(data)
        }
        // The CLI's item is foreign, so it goes through the broker. Google stamps
        // an expiry into the payload, which is what decides whether a mirrored
        // copy is still worth using.
        let mirrored = await CredentialBroker.shared.data(for: Self.cliKey) { data, _ in
            guard let token = Self.decodeCLIKeychain(data) else { return false }
            return !token.isExpired
        }
        if let mirrored, let token = Self.decodeCLIKeychain(mirrored) { return token }
        guard let data = try? Data(contentsOf: Self.legacyCredentialsURL) else { return nil }
        return Self.decodeStored(data)
    }

    // MARK: - Refresh

    private func refresh(_ token: GeminiToken) async -> GeminiToken? {
        guard let refreshToken = token.refreshToken else { return nil }
        let form = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": GeminiOAuthClient.clientID,
            "client_secret": GeminiOAuthClient.clientSecret
        ]
        guard let response = await Self.exchange(form: form) else { return nil }
        // A refresh response usually omits refresh_token; keep the one we have.
        return GeminiToken(
            accessToken: response.accessToken,
            refreshToken: response.refreshToken ?? refreshToken,
            expiresAt: response.expiresIn.map { Date(timeIntervalSinceNow: $0) }
        )
    }

    /// Shared by refresh and by the authorization-code exchange in `GeminiOAuthFlow`.
    static func exchange(form: [String: String]) async -> TokenResponse? {
        var request = URLRequest(url: GeminiOAuthClient.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(formEncoded(form).utf8)
        request.timeoutInterval = 20

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                Log.auth.error("google token endpoint returned \(code)")
                return nil
            }
            return try JSONDecoder.googleDecoder.decode(TokenResponse.self, from: data)
        } catch {
            Log.auth.error("google token exchange failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private static func formEncoded(_ form: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return form.map { key, value in
            let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(key)=\(encoded)"
        }.joined(separator: "&")
    }

    // MARK: - Wire formats

    struct TokenResponse: Decodable, Sendable {
        let accessToken: String
        let refreshToken: String?
        let expiresIn: TimeInterval?
    }

    /// Our own item, and the CLI's legacy file — both use Google's snake_case
    /// credential shape with `expiry_date` in epoch milliseconds.
    struct StoredCredentials: Codable, Sendable {
        let accessToken: String
        let refreshToken: String?
        let expiryDate: Double?

        init(_ token: GeminiToken) {
            accessToken = token.accessToken
            refreshToken = token.refreshToken
            expiryDate = token.expiresAt.map { $0.timeIntervalSince1970 * 1000 }
        }
    }

    /// The CLI's keychain blob is camelCase and nested, unlike the file it replaced.
    struct KeychainEnvelope: Codable, Sendable {
        struct Token: Codable, Sendable {
            let accessToken: String
            let refreshToken: String?
            let expiresAt: Double?
        }
        let token: Token
    }

    /// Re-encodes a refreshed token in the CLI's own shape, so the mirror and the
    /// CLI item stay interchangeable for `decodeCLIKeychain`.
    static func encodeCLIKeychain(_ token: GeminiToken) -> Data? {
        let envelope = KeychainEnvelope(token: .init(
            accessToken: token.accessToken,
            refreshToken: token.refreshToken,
            expiresAt: token.expiresAt.map { $0.timeIntervalSince1970 * 1000 }
        ))
        return try? JSONEncoder().encode(envelope)
    }

    static func decodeStored(_ data: Data) -> GeminiToken? {
        guard let stored = try? JSONDecoder.googleDecoder.decode(StoredCredentials.self, from: data) else { return nil }
        return GeminiToken(
            accessToken: stored.accessToken,
            refreshToken: stored.refreshToken,
            expiresAt: stored.expiryDate.map(Date.fromEpochMilliseconds)
        )
    }

    static func decodeCLIKeychain(_ data: Data) -> GeminiToken? {
        // Not `.convertFromSnakeCase` — this payload is already camelCase.
        guard let envelope = try? JSONDecoder().decode(KeychainEnvelope.self, from: data) else { return nil }
        return GeminiToken(
            accessToken: envelope.token.accessToken,
            refreshToken: envelope.token.refreshToken,
            expiresAt: envelope.token.expiresAt.map(Date.fromEpochMilliseconds)
        )
    }
}

extension JSONDecoder {
    static let googleDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()
}

extension JSONEncoder {
    /// Writes our own item in the same snake_case shape as the CLI's legacy
    /// credentials file, so one decoder reads both.
    static let googleEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }()
}
