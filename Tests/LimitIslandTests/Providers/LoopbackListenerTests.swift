import Foundation
import Testing
@testable import LimitIsland

/// Exercises the real listener over a real loopback socket. This is the test that
/// was missing when the Gemini sign-in shipped broken: `NWListener` refuses to
/// start unless its connection handler is installed before `start()`, and reports
/// the refusal as a bare `EINVAL`. Everything here runs without a browser or any
/// network access beyond 127.0.0.1.
@Suite("Loopback redirect listener")
@MainActor
struct LoopbackRedirectListenerTests {
    private func send(_ path: String, toPort port: UInt16) async throws -> (status: Int, body: String) {
        let url = URL(string: "http://127.0.0.1:\(port)\(path)")!
        let (data, response) = try await URLSession.shared.data(from: url)
        return ((response as? HTTPURLResponse)?.statusCode ?? -1, String(decoding: data, as: UTF8.self))
    }

    /// The real classifier, so these exercise what the sign-in actually does.
    private func listener(expecting state: String = "abc123") -> LoopbackRedirectListener {
        LoopbackRedirectListener { GeminiOAuthFlow.classify($0, expecting: state) }
    }

    @Test("The listener binds loopback and reports its assigned port")
    func binds() async throws {
        // Regression: this threw NWError 22 (Invalid argument) when the
        // connection handler was attached after start().
        let listener = listener()
        defer { listener.cancel() }
        try listener.start()
        #expect(try await listener.port() > 0)
    }

    @Test("A redirect is captured and the browser gets the success page")
    func capturesRequest() async throws {
        let listener = listener()
        defer { listener.cancel() }
        try listener.start()
        let port = try await listener.port()

        async let captured = listener.nextRequest()
        let reply = try await send("/oauth2callback?code=4%2F0AX4&state=abc123", toPort: port)

        #expect(reply.status == 200)
        #expect(reply.body.contains("Signed in"))
        #expect(GeminiOAuthFlow.parseCallback(try await captured, expecting: "abc123") == "4/0AX4")
    }

    @Test("Browser noise before the redirect does not end the wait")
    func ignoresBrowserNoise() async throws {
        // Regression: Chrome preconnects and fetches /favicon.ico around the
        // callback, so the listener saw several connections. Answering the first
        // one it happened to receive failed the sign-in against a favicon.
        let listener = listener()
        defer { listener.cancel() }
        try listener.start()
        let port = try await listener.port()

        async let captured = listener.nextRequest()
        let favicon = try await send("/favicon.ico", toPort: port)
        #expect(favicon.status == 404)

        let reply = try await send("/oauth2callback?code=4%2F0AX4&state=abc123", toPort: port)
        #expect(reply.status == 200)
        #expect(GeminiOAuthFlow.parseCallback(try await captured, expecting: "abc123") == "4/0AX4")
    }

    @Test("A response carrying someone else's state is skipped, not accepted")
    func ignoresForeignState() async throws {
        let listener = listener()
        defer { listener.cancel() }
        try listener.start()
        let port = try await listener.port()

        async let captured = listener.nextRequest()
        _ = try await send("/oauth2callback?code=forged&state=attacker", toPort: port)
        _ = try await send("/oauth2callback?code=real&state=abc123", toPort: port)

        #expect(GeminiOAuthFlow.parseCallback(try await captured, expecting: "abc123") == "real")
    }

    @Test("A declined consent ends the wait rather than hanging")
    func acceptsDenial() async throws {
        let listener = listener()
        defer { listener.cancel() }
        try listener.start()
        let port = try await listener.port()

        async let captured = listener.nextRequest()
        let reply = try await send("/oauth2callback?error=access_denied&state=abc123", toPort: port)

        #expect(reply.status == 400)
        #expect(reply.body.contains("access_denied"))
        #expect(try await captured.contains("error=access_denied"))
    }

    @Test("Two listeners get different ports, so concurrent sign-ins cannot collide")
    func portsAreDistinct() async throws {
        let first = listener()
        let second = listener()
        defer { first.cancel(); second.cancel() }
        try first.start()
        try second.start()
        #expect(try await first.port() != second.port())
    }

    @Test("Cancelling ends the wait instead of hanging")
    func cancelUnblocks() async throws {
        let listener = listener()
        try listener.start()
        _ = try await listener.port()

        let pending = Task { try await listener.nextRequest() }
        listener.cancel()
        await #expect(throws: (any Error).self) { try await pending.value }
    }

    @Test("An explicit failure surfaces to whoever is waiting")
    func failUnblocks() async throws {
        // This is the timeout path: the flow pushes its own error in rather than
        // leaving the caller parked on a port nobody will ever connect to.
        let listener = listener()
        defer { listener.cancel() }
        try listener.start()
        _ = try await listener.port()

        let pending = Task { try await listener.nextRequest() }
        listener.fail(GeminiOAuthError.timedOut)
        await #expect(throws: GeminiOAuthError.self) { try await pending.value }
    }
}

@Suite("Redirect classification")
struct ClassifyTests {
    private func outcome(_ path: String) -> LoopbackOutcome {
        GeminiOAuthFlow.classify("GET \(path) HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n", expecting: "abc123")
    }

    private func isAccepted(_ path: String) -> Bool {
        if case .accept = outcome(path) { return true }
        return false
    }

    @Test("Only the callback path with our own state is accepted")
    func acceptsOnlyOurRedirect() {
        #expect(isAccepted("/oauth2callback?code=x&state=abc123"))
        #expect(isAccepted("/oauth2callback?error=access_denied&state=abc123"))
    }

    @Test("Everything a browser sends alongside the redirect is skipped", arguments: [
        "/favicon.ico",
        "/",
        "/oauth2callback",                          // no query at all
        "/oauth2callback?code=x&state=someone-else",
        "/somewhere-else?code=x&state=abc123"       // right state, wrong path
    ])
    func ignoresEverythingElse(path: String) {
        #expect(isAccepted(path) == false)
    }

    @Test("Skipped requests still get an answer, so the browser shows something")
    func alwaysServesAPage() {
        #expect(outcome("/favicon.ico").page.status == "404 Not Found")
        #expect(outcome("/oauth2callback?code=x&state=abc123").page.status == "200 OK")
        #expect(outcome("/oauth2callback?error=denied&state=abc123").page.status == "400 Bad Request")
    }
}

@Suite("JSON shape diagnostics")
struct JSONShapeTests {
    @Test("The skeleton is reported without any values")
    func describesStructure() {
        let json = Data(#"{"data":[{"uuid":"secret-id","name":"Private Org","seats":5}]}"#.utf8)
        let shape = JSONShape.describe(json)
        #expect(shape.contains("data"))
        #expect(shape.contains("uuid"))
        // The whole point is that it is safe to log.
        #expect(shape.contains("secret-id") == false)
        #expect(shape.contains("Private Org") == false)
    }

    @Test("A bare array and a non-JSON body are both described")
    func describesOtherShapes() {
        #expect(JSONShape.describe(Data(#"[{"uuid":"a"}]"#.utf8)).hasPrefix("[1 ×"))
        #expect(JSONShape.describe(Data("<!doctype html>".utf8)).hasPrefix("not json"))
    }

    @Test("Value types are distinguished, since a number where a string was expected is the usual cause")
    func reportsTypes() {
        let shape = JSONShape.describe(Data(#"{"id":7,"name":"x","ok":true,"gone":null}"#.utf8))
        #expect(shape.contains("id: number"))
        #expect(shape.contains("name: string"))
        #expect(shape.contains("ok: bool"))
        #expect(shape.contains("gone: null"))
    }
}

@Suite("One-shot result")
struct OnceTests {
    @Test("A result settled before anyone waits is still delivered")
    func settlesEarly() async throws {
        // The connection can land before the flow gets round to awaiting it.
        let once = Once<Int>()
        once.resume(returning: 7)
        #expect(try await once.value() == 7)
    }

    @Test("Only the first outcome counts")
    func firstWins() async throws {
        let once = Once<Int>()
        once.resume(returning: 1)
        once.resume(throwing: GeminiOAuthError.timedOut)
        #expect(try await once.value() == 1)
    }

    @Test("A waiter is resumed when the result arrives later")
    func settlesLate() async throws {
        let once = Once<Int>()
        async let value = once.value()
        try await Task.sleep(for: .milliseconds(20))
        once.resume(returning: 42)
        #expect(try await value == 42)
    }
}
