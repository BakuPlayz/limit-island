import Foundation

/// Finds provider logins a CLI has already left on this Mac, so the common case
/// is a one-tap add rather than another browser sign-in.
///
/// Detection never reads a secret. Codex leaves a plain file; Gemini's login now
/// lives in the keychain, but its *presence* can be checked from the item's
/// attributes, which does not unlock it and so does not prompt. The one system
/// authorization prompt happens later, on the first quota read, when the token
/// is actually needed.
enum AccountDetector {
    static func detectedAccounts() -> [DetectedAccount] {
        // Filtered by availability so a hidden provider does not reappear here just
        // because its CLI happens to be signed in on this Mac.
        [codexAccount(), claudeAccount(), geminiAccount()]
            .compactMap { $0 }
            .filter(\.provider.isAvailable)
    }

    /// `codex login` writes a ChatGPT OAuth token here. The identity comes from
    /// the id_token claims so no network call is needed to label the row.
    private static func codexAccount() -> DetectedAccount? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/auth.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = root["tokens"] as? [String: Any],
              (tokens["access_token"] ?? tokens["accessToken"]) != nil else { return nil }

        let claims = idTokenClaims(from: tokens)
        let email = claims?["email"] as? String
        return DetectedAccount(
            provider: .openAI,
            label: email ?? "Codex CLI login",
            credential: .localCLI
        )
    }

    /// Claude Code stores a Claude.ai OAuth session in the login keychain. The
    /// account field is CLI-managed and can vary, so presence is detected by its
    /// stable service name; the organization name is filled in after the user
    /// adds it and permits the one-time keychain read.
    private static func claudeAccount() -> DetectedAccount? {
        guard ClaudeCredentialStore.cliLoginExists() else { return nil }
        return DetectedAccount(
            provider: .claude,
            label: "Claude Code login",
            credential: .localCLI
        )
    }

    /// The `gemini` CLI used to write `~/.gemini/oauth_creds.json`. Current
    /// versions migrate that file into the login keychain and delete it, so
    /// checking only for the file finds nothing on an up-to-date CLI — which is
    /// exactly why Gemini meters never populated.
    private static func geminiAccount() -> DetectedAccount? {
        guard GeminiCredentialStore.cliLoginExists() else { return nil }
        return DetectedAccount(
            provider: .gemini,
            label: GeminiCredentialStore.cliAccountLabel() ?? "Gemini CLI login",
            credential: .localCLI
        )
    }

    static func idTokenClaims(from tokens: [String: Any]) -> [String: Any]? {
        guard let token = (tokens["id_token"] ?? tokens["idToken"]) as? String else { return nil }
        let parts = token.split(separator: ".")
        guard parts.count > 1 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
