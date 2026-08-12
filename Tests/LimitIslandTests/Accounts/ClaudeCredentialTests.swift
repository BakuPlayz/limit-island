import Foundation
import Testing
@testable import LimitIsland

@Suite("Claude credential decoding")
struct ClaudeCredentialTests {
    @Test("The Claude Code keychain blob yields its OAuth access token")
    func decodesCLIKeychain() throws {
        let json = """
        {"claudeAiOauth":{"accessToken":"sk-ant-oat01-demo","refreshToken":"sk-ant-ort01-demo","expiresAt":1786276800000}}
        """
        let token = try #require(ClaudeCredentialStore.decodeCLIKeychain(Data(json.utf8)))
        #expect(token.accessToken == "sk-ant-oat01-demo")
    }

    @Test("Malformed or incomplete credentials are ignored")
    func rejectsInvalidCredentials() {
        #expect(ClaudeCredentialStore.decodeCLIKeychain(Data("{}".utf8)) == nil)
        #expect(ClaudeCredentialStore.decodeCLIKeychain(Data(#"{"claudeAiOauth":{"accessToken":""}}"#.utf8)) == nil)
    }
}
