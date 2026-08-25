import Foundation

/// The single place allowed to read a keychain item this app did not create.
///
/// The problem it solves: reading another app's item with `kSecReturnData` can
/// raise the macOS authorization panel, and the usage readers used to do exactly
/// that on every 60-second poll, for every account. Two accounts meant two panels
/// a minute — the "prompts once per agent" complaint.
///
/// Three things together reduce that to one prompt in the app's lifetime:
///
/// 1. **A memory cache**, so a poll cycle never re-reads what it already has.
/// 2. **A mirror item this app owns.** An item created by this app is unlocked
///    without a prompt, so once a foreign token has been read a single time it is
///    copied to `com.limitisland.credentials` and every later launch reads that
///    instead. The foreign item is only consulted again when the mirror is stale.
/// 3. **Actor serialisation**, so two accounts of the same provider waiting on the
///    same key share one read rather than racing two panels.
///
/// Detection is unaffected: `Keychain.exists` is an attribute-only query that
/// never unlocks anything, so `AccountDetector` still runs prompt-free and does
/// not go through here.
actor CredentialBroker {
    static let shared = CredentialBroker()

    /// Our own mirror. One service, one account per foreign key.
    static let mirrorService = "com.limitisland.credentials"

    /// Identifies a foreign credential, and names its mirror account.
    struct Key: Hashable, Sendable {
        let service: String
        /// `nil` when the owning CLI picks the account field itself, in which case
        /// the lookup matches on service alone.
        let account: String?

        var mirrorAccount: String {
            guard let account else { return service }
            return "\(service)/\(account)"
        }
    }

    /// A mirrored secret plus the moment it was taken. The timestamp is what lets
    /// a caller-supplied validity rule (`isFresh`) reject a copy the owning CLI
    /// has since rotated, without this type having to understand any provider's
    /// token format.
    private struct Entry: Codable, Sendable {
        let data: Data
        let mirroredAt: Date
    }

    private var cache: [Key: Entry] = [:]
    /// Keys whose foreign item has already been consulted this launch. Prevents a
    /// provider that is genuinely signed out from re-prompting every poll.
    private var attemptedThisLaunch: Set<Key> = []

    /// The secret behind `key`, from memory, then our mirror, then — only if
    /// neither is usable — the owning application's item.
    ///
    /// - Parameter isFresh: decides whether a mirrored copy is still good. Called
    ///   with the mirrored bytes and the time they were taken. Providers that
    ///   embed an expiry can parse it; those that do not (Claude) can lean on the
    ///   mirror age and on `invalidate(_:)` from the 401 path.
    func data(for key: Key, isFresh: @Sendable (Data, Date) -> Bool = { _, _ in true }) async -> Data? {
        if let entry = cache[key], isFresh(entry.data, entry.mirroredAt) {
            return entry.data
        }
        // Every stored credential reaches a provider through here, so this is the one
        // place the gate has to be. A refusal reads as "no credential", which the
        // callers already treat as signed out rather than as an error.
        guard await BiometricGate.unlock(reason: "use your saved coding-agent accounts") else {
            Log.auth.info("credential read skipped: locked")
            return nil
        }
        if let entry = readMirror(key), isFresh(entry.data, entry.mirroredAt) {
            cache[key] = entry
            return entry.data
        }
        // Everything below can prompt, so it happens at most once per launch per
        // key even when the account turns out to be signed out.
        guard !attemptedThisLaunch.contains(key) else { return cache[key]?.data }
        attemptedThisLaunch.insert(key)

        guard let fresh = readForeign(key) else {
            Log.auth.error("no credential available for \(key.service, privacy: .public)")
            return nil
        }
        let entry = Entry(data: fresh, mirroredAt: .now)
        cache[key] = entry
        writeMirror(entry, for: key)
        return fresh
    }

    /// Replaces the mirrored copy after this app refreshed a foreign token itself.
    /// The owning CLI keeps its own item untouched — rewriting theirs would rotate
    /// the access token out from under a running CLI — but updating ours means the
    /// next launch has a valid token to read without asking for theirs again.
    func replace(_ data: Data, for key: Key) {
        let entry = Entry(data: data, mirroredAt: .now)
        cache[key] = entry
        writeMirror(entry, for: key)
    }

    /// Drops a credential the provider has rejected, so the next read consults the
    /// owning CLI again. Called from the 401/403 path — for a token with no
    /// embedded expiry, a rejection is the only evidence that it has rotated.
    func invalidate(_ key: Key) {
        cache[key] = nil
        attemptedThisLaunch.remove(key)
        Keychain.remove(service: Self.mirrorService, account: key.mirrorAccount)
    }

    /// Forgets a credential entirely, including the mirror. Used on sign-out.
    func forget(_ key: Key) {
        invalidate(key)
    }

    // MARK: - Storage

    private func readMirror(_ key: Key) -> Entry? {
        // Our own item, so `ownedData` — it adopts the item on the way past, which is
        // what stops a signature change turning "no prompt" back into a prompt on
        // every launch.
        guard let data = Keychain.ownedData(service: Self.mirrorService, account: key.mirrorAccount)
        else { return nil }
        return try? JSONDecoder().decode(Entry.self, from: data)
    }

    private func writeMirror(_ entry: Entry, for key: Key) {
        guard let encoded = try? JSONEncoder().encode(entry) else { return }
        Keychain.set(encoded, service: Self.mirrorService, account: key.mirrorAccount)
    }

    private func readForeign(_ key: Key) -> Data? {
        guard let account = key.account else { return Keychain.data(service: key.service) }
        return Keychain.data(service: key.service, account: account)
    }
}
