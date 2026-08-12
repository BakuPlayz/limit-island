import Foundation

/// Claude Code's local Claude.ai OAuth session. The CLI owns and refreshes this
/// keychain item; Limit Island only ever reads it, and only through
/// `CredentialBroker`, so macOS asks for permission once rather than once per
/// account per poll.
enum ClaudeCredentialStore {
    static let cliService = "Claude Code-credentials"

    /// The CLI chooses its own account field, so the broker matches on service.
    static let cliKey = CredentialBroker.Key(service: cliService, account: nil)

    /// Attribute-only lookup: detection remains silent until a user adds the
    /// account and the first quota refresh needs the token.
    static func cliLoginExists() -> Bool {
        Keychain.exists(service: cliService)
    }

    static func cliToken() async -> ClaudeToken? {
        // Claude Code stamps its own expiry into the item, so a mirrored copy can
        // be checked against the clock instead of being trusted blindly. When the
        // field is absent, fall back to `invalidate(_:)` on a 401 as the only
        // available signal that the CLI has rotated the token.
        let data = await CredentialBroker.shared.data(for: cliKey) { data, _ in
            guard let token = decodeCLIKeychain(data) else { return false }
            guard let expiresAt = token.expiresAt else { return true }
            return expiresAt.timeIntervalSinceNow > 300
        }
        guard let data else { return nil }
        return decodeCLIKeychain(data)
    }

    /// Called when claude.ai rejects the token, which for a credential with no
    /// usable expiry is the only proof that the mirrored copy has gone stale.
    static func invalidate() async {
        await CredentialBroker.shared.invalidate(cliKey)
    }

    struct KeychainEnvelope: Decodable, Sendable {
        struct OAuth: Decodable, Sendable {
            let accessToken: String
            /// Epoch milliseconds. Absent on older CLI versions.
            let expiresAt: Double?
        }

        let claudeAiOauth: OAuth
    }

    static func decodeCLIKeychain(_ data: Data) -> ClaudeToken? {
        guard let envelope = try? JSONDecoder().decode(KeychainEnvelope.self, from: data),
              !envelope.claudeAiOauth.accessToken.isEmpty else { return nil }
        return ClaudeToken(
            accessToken: envelope.claudeAiOauth.accessToken,
            expiresAt: envelope.claudeAiOauth.expiresAt.map(Date.fromEpochMilliseconds)
        )
    }
}

struct ClaudeToken: Sendable, Equatable {
    let accessToken: String
    var expiresAt: Date?
}

extension Date {
    /// Google and Anthropic both write epoch milliseconds in their credential
    /// files; tolerate seconds in case one of them ever does not.
    static func fromEpochMilliseconds(_ value: Double) -> Date {
        Date(timeIntervalSince1970: value > 10_000_000_000 ? value / 1000 : value)
    }
}
