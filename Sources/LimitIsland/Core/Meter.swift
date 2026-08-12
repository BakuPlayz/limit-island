import Foundation

/// How a meter authenticates. Deliberately never surfaced in the UI — the
/// settings screen offers detected accounts and a single "Add account…", and
/// records the right source itself.
enum CredentialSource: Codable, Hashable, Sendable {
    /// Credentials a provider's CLI already left behind, on disk or in the keychain.
    case localCLI
    /// A browser sign-in with its own isolated website data store.
    case browserSession(UUID)
    /// An OAuth grant this app obtained itself, keyed to its own keychain item.
    /// Google's quota endpoint ignores browser cookies, so a Gemini account added
    /// from Settings has to hold a real token rather than a website data store.
    case googleOAuth(UUID)

    var sessionIdentifier: UUID? {
        if case let .browserSession(identifier) = self { return identifier }
        return nil
    }

    var oauthIdentifier: UUID? {
        if case let .googleOAuth(identifier) = self { return identifier }
        return nil
    }
}

/// One account whose quota Limit Island tracks.
///
/// The `side` field earlier builds persisted is gone: the notch no longer arranges
/// rings around the camera housing, so there is nothing to place. Decoding ignores
/// unrecognised keys, so an existing `limit-island.meters` payload still loads.
struct Meter: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var provider: Provider
    /// Identity read back from the provider (email, plan, organization name).
    var detectedLabel: String?
    /// A rename by the user, which always wins over the detected identity.
    var customLabel: String?
    var credential: CredentialSource

    init(
        id: UUID = UUID(),
        provider: Provider,
        detectedLabel: String? = nil,
        customLabel: String? = nil,
        credential: CredentialSource
    ) {
        self.id = id
        self.provider = provider
        self.detectedLabel = detectedLabel
        self.customLabel = customLabel
        self.credential = credential
    }

    var displayLabel: String {
        if let customLabel, !customLabel.isEmpty { return customLabel }
        if let detectedLabel, !detectedLabel.isEmpty { return detectedLabel }
        return provider.title
    }
}

/// A credential found on disk that the user has not added as a meter yet.
struct DetectedAccount: Identifiable, Hashable, Sendable {
    var id: String { "\(provider.rawValue)-\(label)" }
    let provider: Provider
    let label: String
    let credential: CredentialSource
}
