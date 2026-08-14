import Foundation
import Testing
@testable import LimitIsland

@Suite("Gemini credential decoding")
struct GeminiCredentialTests {
    @Test("The OAuth client comes from the environment, then Info.plist, then the bundle")
    func clientResolutionPrecedence() {
        let bundled = Data("bundled-value".utf8).base64EncodedString()
        func resolve(environment: [String: String], info: [String: Any]) -> String {
            GeminiOAuthClient.resolve(
                environmentKey: "KEY",
                infoKey: "InfoKey",
                bundled: bundled,
                environment: environment,
                info: info
            )
        }
        #expect(resolve(environment: ["KEY": "from-env"], info: ["InfoKey": "from-plist"]) == "from-env")
        #expect(resolve(environment: [:], info: ["InfoKey": "from-plist"]) == "from-plist")
        #expect(resolve(environment: [:], info: [:]) == "bundled-value")
        // An empty override is a misconfiguration, not a choice to run with no
        // client — fall through rather than signing in as "".
        #expect(resolve(environment: ["KEY": ""], info: ["InfoKey": ""]) == "bundled-value")
    }

    @Test("The bundled client decodes to a usable Google installed-app client")
    func bundledClientShape() {
        // Asserted by shape, not by literal: the point of storing these base64 is
        // that no copy of the values lives in the repository as plain text.
        #expect(GeminiOAuthClient.clientID.hasSuffix(".apps.googleusercontent.com"))
        #expect(GeminiOAuthClient.clientSecret.hasPrefix("GOCSPX-"))
        #expect(GeminiOAuthClient.clientSecret.count == 35)
    }

    @Test("The CLI's keychain blob decodes")
    func decodesKeychainEnvelope() throws {
        // Shape written by gemini-cli's HybridTokenStorage: camelCase, nested
        // under `token`, expiry in epoch milliseconds.
        let json = """
        {"serverName":"main-account",
         "token":{"accessToken":"ya29.a0","refreshToken":"1//04","tokenType":"Bearer",
                  "scope":"https://www.googleapis.com/auth/cloud-platform","expiresAt":1786276800000},
         "updatedAt":1786273200000}
        """
        let token = try #require(GeminiCredentialStore.decodeCLIKeychain(Data(json.utf8)))
        #expect(token.accessToken == "ya29.a0")
        #expect(token.refreshToken == "1//04")
        #expect(token.expiresAt?.timeIntervalSince1970 == 1_786_276_800)
    }

    @Test("The legacy oauth_creds.json file decodes")
    func decodesLegacyFile() throws {
        // Shape written by older CLI versions, and by this app's own item:
        // snake_case, flat, `expiry_date` in milliseconds.
        let json = """
        {"access_token":"ya29.b1","refresh_token":"1//05","scope":"...",
         "token_type":"Bearer","expiry_date":1786276800000}
        """
        let token = try #require(GeminiCredentialStore.decodeStored(Data(json.utf8)))
        #expect(token.accessToken == "ya29.b1")
        #expect(token.refreshToken == "1//05")
        #expect(token.expiresAt?.timeIntervalSince1970 == 1_786_276_800)
    }

    @Test("The two shapes are not mistaken for each other")
    func shapesDoNotCrossDecode() {
        let keychain = Data(#"{"token":{"accessToken":"a"}}"#.utf8)
        let file = Data(#"{"access_token":"a"}"#.utf8)
        #expect(GeminiCredentialStore.decodeStored(keychain) == nil)
        #expect(GeminiCredentialStore.decodeCLIKeychain(file) == nil)
    }

    @Test("A credential with no expiry is never treated as stale")
    func missingExpiry() {
        #expect(GeminiToken(accessToken: "a", refreshToken: nil, expiresAt: nil).isExpired == false)
    }

    @Test("Expiry uses the CLI's five-minute buffer")
    func expiryBuffer() {
        // A token valid for four more minutes is refreshed rather than sent on a
        // request that might outlive it.
        let almostGone = GeminiToken(accessToken: "a", refreshToken: "r", expiresAt: .now.addingTimeInterval(240))
        let comfortable = GeminiToken(accessToken: "a", refreshToken: "r", expiresAt: .now.addingTimeInterval(600))
        #expect(almostGone.isExpired)
        #expect(comfortable.isExpired == false)
    }

    @Test("Token responses decode with expires_in in seconds")
    func decodesTokenResponse() throws {
        let json = #"{"access_token":"ya29.c2","expires_in":3599,"refresh_token":"1//06","token_type":"Bearer"}"#
        let response = try JSONDecoder.googleDecoder.decode(
            GeminiCredentialStore.TokenResponse.self,
            from: Data(json.utf8)
        )
        #expect(response.accessToken == "ya29.c2")
        #expect(response.expiresIn == 3599)
    }
}

@Suite("Gemini OAuth flow")
struct GeminiOAuthFlowTests {
    @Test("The authorization code is taken from the callback request line")
    func parsesCallback() {
        let request = "GET /oauth2callback?code=4%2F0AX4&state=abc123 HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"
        #expect(GeminiOAuthFlow.parseCallback(request, expecting: "abc123") == "4/0AX4")
    }

    @Test("A mismatched state is rejected")
    func rejectsForgedState() {
        // Guards against another local process racing the browser to the port.
        let request = "GET /oauth2callback?code=4%2F0AX4&state=attacker HTTP/1.1\r\n"
        #expect(GeminiOAuthFlow.parseCallback(request, expecting: "abc123") == nil)
    }

    @Test("A denied consent carries no code")
    func rejectsDenial() {
        let request = "GET /oauth2callback?error=access_denied&state=abc123 HTTP/1.1\r\n"
        #expect(GeminiOAuthFlow.parseCallback(request, expecting: "abc123") == nil)
        #expect(GeminiOAuthFlow.queryItems(in: request)?["error"] == "access_denied")
    }

    @Test("Non-GET and malformed requests are ignored")
    func ignoresJunk() {
        #expect(GeminiOAuthFlow.queryItems(in: "POST /oauth2callback?code=x HTTP/1.1") == nil)
        #expect(GeminiOAuthFlow.queryItems(in: "") == nil)
        #expect(GeminiOAuthFlow.queryItems(in: "garbage") == nil)
    }

    @Test("The PKCE challenge is the base64url SHA-256 of the verifier, unpadded")
    func pkceChallenge() {
        // Vector from RFC 7636 appendix B.
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        #expect(GeminiOAuthFlow.codeChallenge(for: verifier) == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test("Verifiers are URL-safe and unique")
    func randomVerifier() {
        let first = GeminiOAuthFlow.randomURLSafeString()
        let second = GeminiOAuthFlow.randomURLSafeString()
        #expect(first != second)
        #expect(first.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        // RFC 7636 requires a verifier of 43-128 characters.
        #expect(first.count >= 43)
    }

    @Test("The consent URL carries everything Google needs for an offline grant")
    func authorizationURL() throws {
        let url = GeminiOAuthFlow.authorizationURL(
            redirect: "http://127.0.0.1:52345/oauth2callback",
            state: "abc123",
            verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        )
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let query = Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        #expect(query["redirect_uri"] == "http://127.0.0.1:52345/oauth2callback")
        #expect(query["response_type"] == "code")
        #expect(query["code_challenge_method"] == "S256")
        #expect(query["state"] == "abc123")
        // Without these two Google returns no refresh token, and the meter would
        // stop reading an hour later.
        #expect(query["access_type"] == "offline")
        #expect(query["prompt"] == "consent")
        #expect(query["scope"]?.contains("cloud-platform") == true)
    }
}
