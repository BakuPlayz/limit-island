import Foundation
import Security

/// Thin wrapper over the generic-password keychain.
///
/// The distinction that matters here is `exists` versus `data`. Querying
/// attributes does not unlock an item, so `exists` can probe another app's
/// credential silently; asking for `kSecReturnData` is what triggers the macOS
/// authorization prompt. Account *detection* therefore stays quiet and the
/// prompt only appears when a quota read genuinely needs the token.
enum Keychain {
    /// True when an item is present, without reading — and so without prompting.
    static func exists(service: String, account: String) -> Bool {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnAttributes: true
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    /// Some command-line tools choose the macOS account field themselves. Probe
    /// their service without assuming that local username, still without reading
    /// the secret or showing a keychain prompt.
    static func exists(service: String) -> Bool {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecReturnAttributes: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    /// Reads the secret. Raises the system authorization prompt the first time
    /// this app touches an item another app created.
    static func data(service: String, account: String) -> Data? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else {
            // `errSecItemNotFound` is reported too. An item this app wrote itself
            // can start reading as "not found" after the app is re-signed with a
            // different identity, which looks identical to never having signed in
            // — and is exactly what ad-hoc signing does on every build.
            Log.auth.error("keychain read \(service, privacy: .public)/\(account, privacy: .public) failed: OSStatus \(status)")
            return nil
        }
        return result as? Data
    }

    /// Reads one credential stored under a service, for clients whose account
    /// name is not a stable part of their on-disk contract.
    static func data(service: String) -> Data? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else {
            Log.auth.error("keychain read \(service, privacy: .public) failed: OSStatus \(status)")
            return nil
        }
        return result as? Data
    }

    /// Items written here hold provider tokens — our own Gemini credential and the
    /// broker's mirror of a CLI's — so they are marked `WhenUnlocked` rather than
    /// `AfterFirstUnlock`: there is no background work that needs to read a token
    /// while the Mac is locked. The attribute is set on the update path too, so an
    /// item written by an earlier version is upgraded the next time it is touched
    /// rather than keeping the weaker setting forever.
    ///
    /// Worth being plain about the limit: on a file-based login keychain macOS does
    /// not enforce accessibility the way iOS data protection does. This narrows the
    /// window, it does not seal it.
    @discardableResult
    static func set(_ data: Data, service: String, account: String) -> Bool {
        let identity: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]
        let changes: [CFString: Any] = [
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleWhenUnlocked
        ]
        let update = SecItemUpdate(identity as CFDictionary, changes as CFDictionary)
        if update == errSecSuccess { return true }

        var insert = identity
        insert[kSecValueData] = data
        insert[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlocked
        let status = SecItemAdd(insert as CFDictionary, nil)
        if status != errSecSuccess {
            Log.auth.error("keychain write \(service, privacy: .public) failed: \(status)")
        }
        return status == errSecSuccess
    }

    /// Reads one of *our own* items, repairing its ownership the first time.
    ///
    /// `CredentialBroker` is built on "an item this app created is unlocked without a
    /// prompt". That holds only while the app's code signature still matches the one
    /// recorded in the item's ACL — and it stops matching the moment the app is signed
    /// with a different identity, which is what happens to anything written before
    /// `Scripts/build-app.sh` had a stable certificate to use.
    ///
    /// `set` cannot fix it: it updates in place, and an update leaves the original ACL
    /// alone, so the mismatch survives every write and macOS goes on asking for the
    /// login password on every launch. Deleting and re-adding is what makes the
    /// binary running now the owner.
    ///
    /// Only for items this app owns. A foreign item must never be rewritten — that
    /// would rotate a token out from under the CLI that created it.
    static func ownedData(service: String, account: String) -> Data? {
        guard let data = data(service: service, account: account) else { return nil }
        // The read succeeded, which is the only moment the bytes are in hand to write
        // back. Once per item: the repair is needed when the signature drifted, and
        // rewriting a secret on every read is a cost with no matching benefit.
        let identity = "\(service)/\(account)"
        let shouldRepair = repairLock.withLock {
            repairedThisLaunch.insert(identity).inserted
        }
        if shouldRepair, !reauthorize(data, service: service, account: account) {
            Log.auth.error("could not adopt \(service, privacy: .public); it may keep prompting")
        }
        return data
    }

    /// Rewrites an item so its ACL belongs to the binary running now.
    @discardableResult
    static func reauthorize(_ data: Data, service: String, account: String) -> Bool {
        remove(service: service, account: account)
        let insert: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleWhenUnlocked
        ]
        return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
    }

    private nonisolated(unsafe) static var repairedThisLaunch: Set<String> = []
    private static let repairLock = NSLock()

    static func remove(service: String, account: String) {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
