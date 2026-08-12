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

    @discardableResult
    static func set(_ data: Data, service: String, account: String) -> Bool {
        let identity: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]
        let update = SecItemUpdate(identity as CFDictionary, [kSecValueData: data] as CFDictionary)
        if update == errSecSuccess { return true }

        var insert = identity
        insert[kSecValueData] = data
        insert[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(insert as CFDictionary, nil)
        if status != errSecSuccess {
            Log.auth.error("keychain write \(service, privacy: .public) failed: \(status)")
        }
        return status == errSecSuccess
    }

    static func remove(service: String, account: String) {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
