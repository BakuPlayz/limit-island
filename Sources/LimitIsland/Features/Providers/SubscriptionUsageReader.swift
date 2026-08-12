import Foundation
import WebKit

/// Why a read did not produce a number. The distinction matters: a rejected
/// credential should tell the user to sign in, while a timeout should leave the
/// last good reading on screen.
enum ReadError: Error, Equatable {
    case unauthorized
    case http(Int)
    case transport(String)
    case malformed
}

private enum Endpoint {
    static let codexUsage = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    static let claudeOrganizations = URL(string: "https://claude.ai/api/organizations")!
    static let geminiLoadCodeAssist = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist")!
    static let geminiUserQuota = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota")!
    static let geminiUserQuotaSummary = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary")!

    static func claudeUsage(organization: String) -> URL? {
        URL(string: "https://claude.ai/api/organizations/\(organization)/usage")
    }
}

@MainActor
final class SubscriptionUsageReader {
    private var webViews: [UUID: WKWebView] = [:]
    private var dataStores: [UUID: WKWebsiteDataStore] = [:]
    private var hydratedStores: Set<UUID> = []
    /// Gemini's billing project is not persisted by the CLI and does not change
    /// within a session, so it is asked for once per meter and kept.
    private var geminiProjects: [UUID: String?] = [:]

    /// Sent by the login web view, and by the API calls that authenticate with the
    /// cookies that web view collected. Those endpoints sit behind a bot filter
    /// that answers URLSession's default agent with an HTML interstitial and a
    /// 200, so a request has to look like the session it inherited.
    private static let browserUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    func makeLoginView(for meter: Meter) -> WKWebView {
        let view = KeyboardFocusedWebView(frame: .zero, configuration: configuration(for: meter))
        view.allowsBackForwardNavigationGestures = true
        view.customUserAgent = Self.browserUserAgent
        view.load(URLRequest(url: meter.provider.usageURL))
        return view
    }

    /// Reads one account. The native provider APIs are tried first because they
    /// carry reset timestamps; page scraping is a last resort that cannot.
    func read(meter: Meter) async -> SubscriptionUsage {
        do {
            if let usage = try await nativeUsage(for: meter) { return usage }
        } catch let error as ReadError {
            Log.usage.error("\(meter.provider.title, privacy: .public) read failed: \(String(describing: error), privacy: .public)")
            // A credential the provider actively rejected is worth reporting.
            // Falling through to a scrape would only produce the same failure
            // more slowly, and would leave the user with no idea what to do.
            if error == .unauthorized {
                return SubscriptionUsage(provider: meter.provider, fiveHourRemaining: nil, weekRemaining: nil, updatedAt: .now, status: .waitingForSignIn)
            }
        } catch {
            Log.usage.error("\(meter.provider.title, privacy: .public) read failed: \(error.localizedDescription, privacy: .public)")
        }
        return await scrapedUsage(for: meter)
    }

    private func nativeUsage(for meter: Meter) async throws -> SubscriptionUsage? {
        switch meter.provider {
        case .openAI:
            if meter.credential == .localCLI { return try await codexCLIUsage() }
            return try await codexWebUsage(meter: meter)
        case .claude:
            if meter.credential == .localCLI { return try await claudeCLIUsage() }
            return try await claudeWebUsage(meter: meter)
        case .gemini:
            return try await geminiUsage(meter: meter)
        }
    }

    /// Reads back who an account is signed in as, for the meter label.
    func detectIdentity(for meter: Meter) async -> String? {
        do {
            switch meter.provider {
            case .openAI:
                guard meter.credential == .localCLI, let request = codexCLIRequest() else { return nil }
                return try await fetch(CodexUsageResponse.self, request, as: "codex identity").identity
            case .claude:
                if meter.credential == .localCLI {
                    guard let token = await ClaudeCredentialStore.cliToken() else { return nil }
                    return try await fetch(
                        ClaudeOrganizations.self,
                        claudeRequest(Endpoint.claudeOrganizations, bearerToken: token.accessToken),
                        as: "claude CLI identity"
                    ).name
                }
                guard let header = await cookieHeader(for: meter, domain: "claude.ai") else { return nil }
                let request = claudeRequest(Endpoint.claudeOrganizations, cookieHeader: header)
                return try await fetch(ClaudeOrganizations.self, request, as: "claude identity").name
            case .gemini:
                return try await geminiIdentity(for: meter)
            }
        } catch {
            Log.usage.debug("identity lookup for \(meter.provider.title, privacy: .public) failed")
            return nil
        }
    }

    func clearSession(for meter: Meter) async {
        webViews[meter.id]?.stopLoading()
        webViews[meter.id] = nil
        geminiProjects[meter.id] = nil
        if meter.provider == .gemini {
            await GeminiCredentialStore.shared.signOut(meter.credential)
        }
        guard let identifier = meter.credential.sessionIdentifier else { return }
        hydratedStores.remove(identifier)
        let store = dataStore(identifier: identifier)
        let dataTypes = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await store.dataRecords(ofTypes: dataTypes)
        await withCheckedContinuation { continuation in
            store.removeData(ofTypes: dataTypes, for: records) { continuation.resume() }
        }
    }

    // MARK: - Codex

    private func codexCLIRequest() -> URLRequest? {
        let authURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/auth.json")
        guard let data = try? Data(contentsOf: authURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = root["tokens"] as? [String: Any],
              let accessToken = (tokens["access_token"] ?? tokens["accessToken"]) as? String,
              let accountID = Self.accountID(from: tokens) else { return nil }

        var request = URLRequest(url: Endpoint.codexUsage)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(accountID, forHTTPHeaderField: "chatgpt-account-id")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        return request
    }

    /// Codex CLI keeps its ChatGPT subscription OAuth token locally after
    /// `codex login`. This reads it in-place and never copies or persists it.
    private func codexCLIUsage() async throws -> SubscriptionUsage? {
        guard let request = codexCLIRequest() else { return nil }
        return try await fetch(CodexUsageResponse.self, request, as: "codex usage").usage
    }

    /// A Codex account signed in through the browser rather than the CLI. The
    /// same endpoint answers to session cookies.
    private func codexWebUsage(meter: Meter) async throws -> SubscriptionUsage? {
        guard let header = await cookieHeader(for: meter, domain: "chatgpt.com") else { return nil }
        var request = URLRequest(url: Endpoint.codexUsage)
        request.setValue(header, forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("https://chatgpt.com", forHTTPHeaderField: "Referer")
        request.setValue(Self.browserUserAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        return try await fetch(CodexUsageResponse.self, request, as: "codex web usage").usage
    }

    private static func accountID(from tokens: [String: Any]) -> String? {
        if let id = (tokens["account_id"] ?? tokens["accountId"]) as? String, !id.isEmpty { return id }
        guard let claims = AccountDetector.idTokenClaims(from: tokens) else { return nil }
        if let auth = claims["https://api.openai.com/auth"] as? [String: Any],
           let id = auth["chatgpt_account_id"] as? String { return id }
        return claims["chatgpt_account_id"] as? String
    }

    // MARK: - Claude

    /// Claude Code's local OAuth token is accepted by the same organization and
    /// usage endpoints as claude.ai. It stays in the CLI's keychain item; this
    /// app reads it only for the request and never persists or refreshes it.
    private func claudeCLIUsage() async throws -> SubscriptionUsage? {
        guard let token = await ClaudeCredentialStore.cliToken() else { throw ReadError.unauthorized }
        do {
            return try await claudeUsage(
                organizationsRequest: claudeRequest(Endpoint.claudeOrganizations, bearerToken: token.accessToken),
                usageRequest: { claudeRequest($0, bearerToken: token.accessToken) },
                label: "claude CLI"
            )
        } catch ReadError.unauthorized {
            // Claude Code's item does not always carry an expiry, so a rejection
            // is the only proof that the CLI has rotated the token since we
            // mirrored it. Drop the mirror; the next refresh reads theirs again.
            await ClaudeCredentialStore.invalidate()
            throw ReadError.unauthorized
        }
    }

    /// Claude's web client exposes organization usage to the same signed-in session.
    private func claudeWebUsage(meter: Meter) async throws -> SubscriptionUsage? {
        guard let header = await cookieHeader(for: meter, domain: "claude.ai") else { return nil }
        return try await claudeUsage(
            organizationsRequest: claudeRequest(Endpoint.claudeOrganizations, cookieHeader: header),
            usageRequest: { claudeRequest($0, cookieHeader: header) },
            label: "claude"
        )
    }

    private func claudeUsage(
        organizationsRequest: URLRequest,
        usageRequest: (URL) -> URLRequest,
        label: String
    ) async throws -> SubscriptionUsage? {
        let organizations = try await fetch(
            ClaudeOrganizations.self,
            organizationsRequest,
            as: "\(label) organizations"
        )
        guard let identifier = organizations.identifier,
              let usageURL = Endpoint.claudeUsage(organization: identifier) else {
            // The decoder no longer throws on an unfamiliar payload, so say
            // something here — otherwise an empty result is indistinguishable
            // from "this account has no organizations", which is how this path
            // stayed broken and invisible before.
            Log.usage.error("claude returned \(organizations.organizations.count) organizations but no usable id")
            return nil
        }
        return try await fetch(
            ClaudeUsageResponse.self,
            usageRequest(usageURL),
            as: "\(label) usage"
        ).usage
    }

    private func claudeRequest(_ url: URL, cookieHeader: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("https://claude.ai", forHTTPHeaderField: "Origin")
        request.setValue("https://claude.ai", forHTTPHeaderField: "Referer")
        request.setValue(Self.browserUserAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        return request
    }

    private func claudeRequest(_ url: URL, bearerToken: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("https://claude.ai", forHTTPHeaderField: "Origin")
        request.setValue("https://claude.ai", forHTTPHeaderField: "Referer")
        request.setValue(Self.browserUserAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        return request
    }

    // MARK: - Gemini

    private struct LoadCodeAssistRequest: Encodable {
        struct Metadata: Encodable {
            let ideType = "IDE_UNSPECIFIED"
            let platform = "PLATFORM_UNSPECIFIED"
            let pluginType = "GEMINI"
        }
        var cloudaicompanionProject: String?
        let metadata = Metadata()
    }

    private struct RetrieveUserQuotaRequest: Encodable {
        var project: String?
    }

    /// Gemini Code Assist exposes remaining quota through the Cloud Code endpoint
    /// the Gemini CLI itself uses. It needs a real OAuth access token — browser
    /// cookies do not authenticate it — which comes either from the CLI's login
    /// or from this app's own sign-in.
    private func geminiUsage(meter: Meter) async throws -> SubscriptionUsage? {
        guard let token = await GeminiCredentialStore.shared.token(for: meter.credential) else {
            // Say so rather than falling through silently. A Gemini meter has no
            // browser session to scrape, so no credential means no reading at
            // all — which previously just left the last good percentage on
            // screen indefinitely.
            Log.auth.error("no gemini credential available for this account")
            throw ReadError.unauthorized
        }
        let project: String?
        do {
            project = try await geminiProject(for: meter, token: token)
        } catch ReadError.unauthorized {
            // Same reasoning as Claude: a rejected token means our mirrored copy
            // of the CLI's credential is behind theirs.
            if meter.credential == .localCLI {
                await CredentialBroker.shared.invalidate(GeminiCredentialStore.cliKey)
            }
            throw ReadError.unauthorized
        }
        let body = RetrieveUserQuotaRequest(project: project)

        // The per-model endpoint only supplies the short/session quota. Google
        // exposes the weekly pool alongside it through the quota summary. Keep
        // the old endpoint as a fallback for accounts where the summary RPC has
        // not rolled out yet.
        let summaryRequest = try geminiRequest(Endpoint.geminiUserQuotaSummary, token: token, body: body)
        if var usage = try? await fetch(GeminiQuotaSummaryResponse.self, summaryRequest, as: "gemini quota summary").usage {
            if usage.fiveHourRemaining == nil {
                let quotaRequest = try geminiRequest(Endpoint.geminiUserQuota, token: token, body: body)
                if let shortWindow = try? await fetch(GeminiQuotaResponse.self, quotaRequest, as: "gemini quota").usage {
                    usage.fiveHourRemaining = shortWindow.fiveHourRemaining
                    usage.fiveHourResetAt = shortWindow.fiveHourResetAt
                }
            }
            return usage
        }

        let quotaRequest = try geminiRequest(Endpoint.geminiUserQuota, token: token, body: body)
        return try await fetch(GeminiQuotaResponse.self, quotaRequest, as: "gemini quota").usage
    }

    /// The quota is billed against a Code Assist project the CLI resolves at
    /// startup and never writes down, so it has to be asked for the same way.
    /// (`~/.gemini/projects.json` looks like it holds this but does not — it is a
    /// local path-to-slug registry for the CLI's own history directories.)
    private func geminiProject(for meter: Meter, token: GeminiToken) async throws -> String? {
        if let cached = geminiProjects[meter.id] { return cached }
        let environment = ProcessInfo.processInfo.environment
        let override = environment["GOOGLE_CLOUD_PROJECT"] ?? environment["GOOGLE_CLOUD_PROJECT_ID"]
        let request = try geminiRequest(
            Endpoint.geminiLoadCodeAssist,
            token: token,
            body: LoadCodeAssistRequest(cloudaicompanionProject: override)
        )
        let response = try await fetch(LoadCodeAssistResponse.self, request, as: "gemini loadCodeAssist")
        let project = response.cloudaicompanionProject ?? override
        geminiProjects[meter.id] = project
        return project
    }

    private func geminiRequest(_ url: URL, token: GeminiToken, body: some Encodable) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("LimitIsland (macOS)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    private func geminiIdentity(for meter: Meter) async throws -> String? {
        if meter.credential == .localCLI, let label = GeminiCredentialStore.cliAccountLabel() { return label }
        guard let token = await GeminiCredentialStore.shared.token(for: meter.credential) else { return nil }
        var request = URLRequest(url: GeminiOAuthClient.userInfoEndpoint)
        request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        return try await fetch(GoogleUserInfo.self, request, as: "google userinfo").email
    }

    // MARK: - Transport

    private func fetch<T: Decodable>(_ type: T.Type, _ request: URLRequest, as label: String) async throws -> T {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw ReadError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw ReadError.malformed }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 || http.statusCode == 403 { throw ReadError.unauthorized }
            throw ReadError.http(http.statusCode)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            // The content type separates "the provider served us an HTML bot
            // check" from "the JSON shape changed and the model is wrong", and
            // the shape says which part of the shape moved. Both are metadata —
            // no values are logged, because the body carries account data.
            let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? "none"
            Log.usage.error("""
                \(label, privacy: .public) response did not decode \
                (content-type \(contentType, privacy: .public), \
                shape \(JSONShape.describe(data), privacy: .public)): \
                \(error.localizedDescription, privacy: .public)
                """)
            throw ReadError.malformed
        }
    }

    // MARK: - Page scraping fallback

    private func scrapedUsage(for meter: Meter) async -> SubscriptionUsage {
        guard meter.credential.sessionIdentifier != nil else { return .empty(meter.provider) }
        let view = webView(for: meter)
        view.load(URLRequest(url: meter.provider.usageURL))
        try? await Task.sleep(for: .seconds(5))
        do {
            let text = try await documentText(from: view)
            let values = SubscriptionTextParser.percentages(from: text)
            return SubscriptionUsage(
                provider: meter.provider,
                fiveHourRemaining: values.fiveHour,
                weekRemaining: values.week,
                fiveHourResetAt: nil,
                weekResetAt: nil,
                updatedAt: .now,
                status: values.fiveHour == nil && values.week == nil ? .unavailable : .ready
            )
        } catch {
            // A WebKit failure here says nothing about whether the session is
            // valid, so report it as unavailable rather than telling the user to
            // sign in again.
            Log.usage.error("scraping \(meter.provider.title, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return SubscriptionUsage(provider: meter.provider, fiveHourRemaining: nil, weekRemaining: nil, updatedAt: .now, status: .unavailable)
        }
    }

    private func documentText(from webView: WKWebView) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript("document.body ? document.body.innerText : ''") { result, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: result as? String ?? "") }
            }
        }
    }

    // MARK: - Browser sessions

    private func webView(for meter: Meter) -> WKWebView {
        if let existing = webViews[meter.id] { return existing }
        let view = KeyboardFocusedWebView(frame: .zero, configuration: configuration(for: meter))
        view.customUserAgent = Self.browserUserAgent
        webViews[meter.id] = view
        return view
    }

    private func configuration(for meter: Meter) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        if let identifier = meter.credential.sessionIdentifier {
            configuration.websiteDataStore = dataStore(identifier: identifier)
        }
        configuration.preferences.isTextInteractionEnabled = true
        return configuration
    }

    /// Data stores must be cached, not rebuilt per call. A freshly constructed
    /// `WKWebsiteDataStore(forIdentifier:)` does not immediately see the
    /// persisted cookies, so recreating one every refresh made the signed-in
    /// session look empty and silently pushed reads onto the scraping fallback.
    private func dataStore(identifier: UUID) -> WKWebsiteDataStore {
        if let existing = dataStores[identifier] { return existing }
        let store = WKWebsiteDataStore(forIdentifier: identifier)
        dataStores[identifier] = store
        return store
    }

    /// A newly constructed store reports an empty cookie jar even when one is
    /// persisted on disk; querying its data records first forces it to load.
    /// Without this the signed-in session looks absent and the read silently
    /// degrades to page scraping, which yields stale numbers and no reset dates.
    private func hydratedDataStore(identifier: UUID) async -> WKWebsiteDataStore {
        let store = dataStore(identifier: identifier)
        if hydratedStores.contains(identifier) { return store }
        _ = await store.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
        hydratedStores.insert(identifier)
        return store
    }

    /// Cookies for one signed-in browser session, keyed to a domain.
    private func cookieHeader(for meter: Meter, domain: String) async -> String? {
        guard let identifier = meter.credential.sessionIdentifier else { return nil }
        let store = await hydratedDataStore(identifier: identifier)
        let cookies = await store.httpCookieStore.allCookies().filter { $0.domain.contains(domain) }
        guard !cookies.isEmpty else { return nil }
        return cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }
}

private final class KeyboardFocusedWebView: WKWebView {
    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }
}
