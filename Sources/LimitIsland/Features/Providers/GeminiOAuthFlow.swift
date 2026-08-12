import AppKit
import CryptoKit
import Foundation

enum GeminiOAuthError: LocalizedError {
    case listenerFailed(String)
    case timedOut
    case stateMismatch
    case denied(String)
    case exchangeFailed

    var errorDescription: String? {
        switch self {
        case let .listenerFailed(reason): "Could not open a local port for the sign-in: \(reason)"
        case .timedOut: "The Google sign-in was not completed."
        case .stateMismatch: "The sign-in response did not match this request."
        case let .denied(reason): "Google declined the sign-in: \(reason)"
        case .exchangeFailed: "Google did not return an access token."
        }
    }
}

/// Google's consent flow, driven the way the Gemini CLI drives it: the consent
/// page opens in the user's real browser and the authorization code comes back
/// to a short-lived loopback listener.
///
/// The sign-in window used for Claude and Codex is not an option here — Google
/// serves `disallowed_useragent` to embedded web views regardless of the user
/// agent they claim. The listener only ever accepts one request and is torn down
/// immediately afterwards.
@MainActor
final class GeminiOAuthFlow {
    private var listener: LoopbackRedirectListener?
    private var timeout: Task<Void, Never>?

    /// How long the consent page stays answerable before the port is closed.
    private static let window: Duration = .seconds(300)

    func signIn() async throws -> GeminiToken {
        let verifier = Self.randomURLSafeString()
        let state = Self.randomURLSafeString()

        // Classification happens while the request is being answered, so it has
        // to know the same `state` the code check uses.
        let listener = LoopbackRedirectListener { request in
            Self.classify(request, expecting: state)
        }
        self.listener = listener
        defer { cancel() }

        do {
            try listener.start()
        } catch {
            throw GeminiOAuthError.listenerFailed(error.localizedDescription)
        }
        let port: UInt16
        do {
            port = try await listener.port()
        } catch {
            throw GeminiOAuthError.listenerFailed(error.localizedDescription)
        }

        let redirect = "http://127.0.0.1:\(port)/oauth2callback"
        NSWorkspace.shared.open(Self.authorizationURL(redirect: redirect, state: state, verifier: verifier))
        Log.auth.info("gemini sign-in listening on 127.0.0.1:\(port, privacy: .public)")

        let code = try await authorizationCode(from: listener, expecting: state)
        guard let response = await GeminiCredentialStore.exchange(form: [
            "grant_type": "authorization_code",
            "code": code,
            "code_verifier": verifier,
            "redirect_uri": redirect,
            "client_id": GeminiOAuthClient.clientID,
            "client_secret": GeminiOAuthClient.clientSecret
        ]) else { throw GeminiOAuthError.exchangeFailed }

        return GeminiToken(
            accessToken: response.accessToken,
            refreshToken: response.refreshToken,
            expiresAt: response.expiresIn.map { Date(timeIntervalSinceNow: $0) }
        )
    }

    func cancel() {
        timeout?.cancel()
        timeout = nil
        listener?.cancel()
        listener = nil
    }

    // MARK: - Waiting for the redirect

    private func authorizationCode(from listener: LoopbackRedirectListener, expecting state: String) async throws -> String {
        timeout = Task { [weak self] in
            try? await Task.sleep(for: Self.window)
            guard !Task.isCancelled else { return }
            self?.listener?.fail(GeminiOAuthError.timedOut)
        }

        let request = try await listener.nextRequest()
        guard let code = Self.parseCallback(request, expecting: state) else {
            throw Self.failure(in: request)
        }
        return code
    }

    /// Sorts the redirect from everything else the browser sends at the port, and
    /// decides what the user is shown — they never return to the app on their
    /// own, so the page is the only feedback they get.
    ///
    /// Only a request to the callback path carrying our own `state` ends the
    /// wait. Favicon fetches, preconnects and anything with a state we did not
    /// issue are answered and skipped, so a stray request cannot end a sign-in
    /// that is still in progress.
    nonisolated static func classify(_ request: String, expecting state: String) -> LoopbackOutcome {
        guard let query = queryItems(in: request), isCallbackPath(request) else {
            return .ignore(.notFound)
        }
        guard query["state"] == state else {
            if query["state"] != nil { Log.auth.error("gemini sign-in state mismatch; ignoring") }
            return .ignore(.notFound)
        }
        if let error = query["error"] {
            // The user declined, or Google refused. That is a real answer.
            return .accept(.badRequest(
                "Sign-in failed",
                "Google reported \"\(error)\". You can close this tab and try again."
            ))
        }
        guard let code = query["code"], !code.isEmpty else {
            return .accept(.badRequest(
                "Sign-in failed",
                "LimitIsland did not receive an authorization code. You can close this tab and try again."
            ))
        }
        return .accept(.ok(
            "Signed in",
            "LimitIsland now has access to your Gemini quota. You can close this tab."
        ))
    }

    nonisolated private static func isCallbackPath(_ request: String) -> Bool {
        guard let line = request.split(whereSeparator: \.isNewline).first else { return false }
        let fields = line.split(separator: " ")
        guard fields.count >= 2 else { return false }
        return fields[1].hasPrefix("/oauth2callback")
    }

    // MARK: - Parsing

    /// Pulls `code` out of the request line, rejecting a response whose `state`
    /// does not match the one we sent.
    nonisolated static func parseCallback(_ request: String, expecting state: String) -> String? {
        guard let query = queryItems(in: request), query["state"] == state else { return nil }
        guard let code = query["code"], !code.isEmpty else { return nil }
        return code
    }

    nonisolated private static func failure(in request: String) -> GeminiOAuthError {
        guard let query = queryItems(in: request) else { return .timedOut }
        if let state = query["state"], !state.isEmpty, query["error"] == nil { return .stateMismatch }
        return .denied(query["error"] ?? "no authorization code")
    }

    nonisolated static func queryItems(in request: String) -> [String: String]? {
        guard let line = request.split(whereSeparator: \.isNewline).first else { return nil }
        let fields = line.split(separator: " ")
        guard fields.count >= 2, fields[0] == "GET" else { return nil }
        guard var components = URLComponents(string: String(fields[1])) else { return nil }
        // A relative request target has no scheme; give it one so `queryItems` parses.
        if components.scheme == nil { components = URLComponents(string: "http://127.0.0.1" + fields[1])! }
        return Dictionary(
            (components.queryItems ?? []).map { ($0.name, $0.value ?? "") },
            uniquingKeysWith: { first, _ in first }
        )
    }

    // MARK: - Request

    nonisolated static func authorizationURL(redirect: String, state: String, verifier: String) -> URL {
        var components = URLComponents(url: GeminiOAuthClient.authorizationEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            .init(name: "client_id", value: GeminiOAuthClient.clientID),
            .init(name: "redirect_uri", value: redirect),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: GeminiOAuthClient.scopes.joined(separator: " ")),
            .init(name: "state", value: state),
            .init(name: "code_challenge", value: codeChallenge(for: verifier)),
            .init(name: "code_challenge_method", value: "S256"),
            // Together these are what guarantee a refresh token comes back, so
            // the meter keeps working past the access token's first hour.
            .init(name: "access_type", value: "offline"),
            .init(name: "prompt", value: "consent")
        ]
        return components.url!
    }

    nonisolated static func codeChallenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded
    }

    nonisolated static func randomURLSafeString(byteCount: Int = 32) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        return Data(bytes).base64URLEncoded
    }
}

extension Data {
    var base64URLEncoded: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

