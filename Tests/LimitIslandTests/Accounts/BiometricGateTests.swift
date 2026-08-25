import Foundation
import Testing
@testable import LimitIsland

@MainActor
@Suite("Credential lock", .serialized)
struct BiometricGateTests {
    /// The gate reads one defaults key and one static. Both are process-wide, so each
    /// test puts them back rather than leaving the next one — or the running app —
    /// with a lock it did not ask for.
    private func withGate(enabled: Bool, _ body: () -> Void) {
        let previousEnabled = BiometricGate.isEnabled
        BiometricGate.isEnabled = enabled
        BiometricGate.relock()
        body()
        BiometricGate.isEnabled = previousEnabled
        BiometricGate.relock()
    }

    @Test("Off by default, so a fresh install is never locked out")
    func defaultsToOff() {
        // A biometric gate that switches itself on is how someone loses access to
        // their own accounts on a build they compiled themselves.
        let suite = UserDefaults(suiteName: UUID().uuidString)!
        #expect(suite.bool(forKey: "limit-island.require-biometrics") == false)
    }

    @Test("A disabled gate passes without asking anything")
    func disabledGatePasses() async {
        await withGateAsync(enabled: false) {
            #expect(await BiometricGate.unlock(reason: "test"))
            // And it must not have recorded a decision it never made.
            #expect(BiometricGate.state != .refused)
        }
    }

    @Test("A refusal is remembered for the launch rather than re-asked")
    func refusalIsSticky() {
        withGate(enabled: true) {
            BiometricGate.setStateForTesting(.refused)
            // The quota poller runs every 60s. Without this, a cancelled prompt would
            // come back a minute later, and then a minute after that — which is
            // attrition, not consent.
            #expect(BiometricGate.state == .refused)
            BiometricGate.relock()
            #expect(BiometricGate.state == .unknown)
        }
    }

    @Test("Turning the gate off clears a refusal")
    func disablingClearsRefusal() {
        withGate(enabled: true) {
            BiometricGate.setStateForTesting(.refused)
            BiometricGate.isEnabled = false
            // Otherwise the accounts stay unreadable for the rest of the launch with
            // the toggle already off and nothing left on screen explaining why.
            #expect(BiometricGate.state != .refused)
            #expect(BiometricGate.isEnabled == false)
        }
    }

    private func withGateAsync(enabled: Bool, _ body: () async -> Void) async {
        let previousEnabled = BiometricGate.isEnabled
        BiometricGate.isEnabled = enabled
        BiometricGate.relock()
        await body()
        BiometricGate.isEnabled = previousEnabled
        BiometricGate.relock()
    }
}
