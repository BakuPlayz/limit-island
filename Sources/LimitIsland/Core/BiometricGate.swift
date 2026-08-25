import Foundation
import LocalAuthentication

/// Touch ID in front of the app's stored credentials, once per launch.
///
/// Worth being plain about what this is and is not. It is *not* biometric protection
/// on the keychain items themselves: that needs `kSecAttrAccessControl` on the
/// data-protection keychain, which needs a real team identifier, and this app is
/// signed with a self-signed local certificate (`Scripts/build-app.sh`). Asking for it
/// returns `errSecMissingEntitlement`. So the macOS keychain panel cannot be turned
/// into a Touch ID panel from here.
///
/// What this is: the app declining to use credentials it can already read until the
/// person at the keyboard proves they are the owner. A weaker promise, honestly kept,
/// rather than a stronger one that cannot be made on this build.
@MainActor
enum BiometricGate {
    enum State: Equatable {
        /// Not asked yet this launch.
        case unknown
        /// Proven, and trusted until the app quits.
        case unlocked
        /// Cancelled or failed. Deliberately sticky — see `unlock`.
        case refused
    }

    private(set) static var state: State = .unknown

    private enum DefaultsKey {
        static let required = "limit-island.require-biometrics"
    }

    /// Off unless chosen. A biometric gate that switches itself on is a good way to
    /// lock someone out of their own accounts on a build they compiled themselves.
    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: DefaultsKey.required) }
        set {
            UserDefaults.standard.set(newValue, forKey: DefaultsKey.required)
            // Turning it off has to clear a refusal too, or the credentials stay
            // unreadable for the rest of the launch with nothing left explaining why.
            if !newValue { state = .unlocked }
        }
    }

    /// Whether this Mac can ask at all. Read for the Settings copy, so the toggle can
    /// explain itself on a machine with no Touch ID rather than silently doing nothing.
    static var isAvailable: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    static var biometryName: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
        switch context.biometryType {
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        case .faceID: return "Face ID"
        default: return "your password"
        }
    }

    /// Passes when the gate is off, unavailable, or already satisfied this launch.
    ///
    /// A refusal is remembered for the rest of the launch rather than retried. The
    /// quota poller runs every 60 seconds (`QuotaStore.start`), and a gate that asked
    /// again on every cycle would be a Touch ID prompt a minute until the person gave
    /// in — which is not consent, only attrition. `relock()` is the way back.
    static func unlock(reason: String) async -> Bool {
        guard isEnabled else { return true }
        switch state {
        case .unlocked: return true
        case .refused: return false
        case .unknown: break
        }

        let context = LAContext()
        // `deviceOwnerAuthentication`, not the biometrics-only policy: a Mac without
        // Touch ID, or a finger that will not read, falls back to the login password
        // instead of making the account permanently unreadable.
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) else {
            state = .unlocked
            return true
        }

        do {
            let granted = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            state = granted ? .unlocked : .refused
            return granted
        } catch {
            Log.auth.info("biometric unlock declined: \(String(describing: error), privacy: .public)")
            state = .refused
            return false
        }
    }

    /// Clears a refusal so the next read may ask again. Wired to the Settings button,
    /// because a person who changed their mind needs somewhere to say so.
    static func relock() {
        state = .unknown
    }

    /// Tests drive the states without a Touch ID sensor. Nothing else sets one by
    /// hand — the whole point is that only `unlock` can grant it.
    static func setStateForTesting(_ state: State) {
        self.state = state
    }
}
