import Foundation
import Testing
@testable import LimitIsland

@Suite("Keychain ownership repair")
struct KeychainRepairTests {
    /// A unique service per run, removed afterwards, so a test never collides with
    /// the running app's real credentials.
    private func withScratchItem(_ body: (String, String) throws -> Void) rethrows {
        let service = "com.limitisland.tests.\(UUID().uuidString)"
        let account = "scratch"
        defer { Keychain.remove(service: service, account: account) }
        try body(service, account)
    }

    @Test("Repairing an item keeps its secret")
    func repairRoundTrips() throws {
        // The repair deletes before it adds. If that ever stopped writing the bytes
        // back, the app would silently destroy the credential it was trying to keep.
        try withScratchItem { service, account in
            let secret = Data("a-token-worth-not-losing".utf8)
            #expect(Keychain.set(secret, service: service, account: account))
            #expect(Keychain.reauthorize(secret, service: service, account: account))
            #expect(Keychain.data(service: service, account: account) == secret)
        }
    }

    @Test("An owned read returns the same bytes as a plain one")
    func ownedReadMatches() throws {
        try withScratchItem { service, account in
            let secret = Data(#"{"access_token":"x"}"#.utf8)
            #expect(Keychain.set(secret, service: service, account: account))
            // Reads twice: the repair runs on the first and must not disturb the
            // second, since every later launch depends on the item still being there.
            #expect(Keychain.ownedData(service: service, account: account) == secret)
            #expect(Keychain.ownedData(service: service, account: account) == secret)
        }
    }

    @Test("A missing item repairs nothing and reports nothing")
    func missingItemIsQuiet() {
        let service = "com.limitisland.tests.absent.\(UUID().uuidString)"
        #expect(Keychain.ownedData(service: service, account: "none") == nil)
        #expect(Keychain.exists(service: service, account: "none") == false)
    }
}
