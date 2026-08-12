import Foundation
import Network

/// What the browser is shown after it delivers the redirect.
struct LoopbackPage: Sendable {
    var status: String
    var title: String
    var detail: String

    static func ok(_ title: String, _ detail: String) -> LoopbackPage {
        LoopbackPage(status: "200 OK", title: title, detail: detail)
    }

    static func badRequest(_ title: String, _ detail: String) -> LoopbackPage {
        LoopbackPage(status: "400 Bad Request", title: title, detail: detail)
    }

    static let notFound = LoopbackPage(status: "404 Not Found", title: "Not found", detail: "")
}

/// Whether a request was the one being waited for.
///
/// A browser does not open exactly one connection. Chrome in particular
/// speculatively preconnects and then asks for `/favicon.ico` once the callback
/// page renders, so the listener sees several requests and only one of them is
/// the redirect. Treating the first arrival as the answer meant the sign-in
/// failed against a favicon request.
enum LoopbackOutcome: Sendable {
    /// The awaited request. Serve this page and stop listening.
    case accept(LoopbackPage)
    /// Something else. Serve this page and keep waiting.
    case ignore(LoopbackPage)

    var page: LoopbackPage {
        switch self {
        case let .accept(page), let .ignore(page): page
        }
    }
}

enum LoopbackListenerError: LocalizedError {
    case couldNotBind(String)
    case noPortAssigned
    case cancelled

    var errorDescription: String? {
        switch self {
        case let .couldNotBind(reason): "Could not open a local port: \(reason)"
        case .noPortAssigned: "The local port was opened but never reported."
        case .cancelled: "The local port was closed before a response arrived."
        }
    }
}

/// An HTTP listener on `127.0.0.1`, for catching an OAuth redirect.
///
/// Loopback-only on a port the system assigns, so nothing is reachable off the
/// machine and two sign-ins can never collide on a fixed port. It keeps serving
/// requests until the caller's `classify` closure accepts one, then stops.
///
/// Split out from the sign-in flow purely so it can be tested: the flow itself
/// opens a browser, which no test can drive, and both bugs this type has had
/// were in exactly the parts a browser is not needed to exercise.
@MainActor
final class LoopbackRedirectListener {
    /// Decides whether a request is the awaited one, and what to serve back.
    private let classify: @Sendable (String) -> LoopbackOutcome
    private var listener: NWListener?
    private let portBox = Once<UInt16>()
    private let requestBox = Once<String>()

    init(classify: @escaping @Sendable (String) -> LoopbackOutcome) {
        self.classify = classify
    }

    deinit {
        let listener = listener
        listener?.cancel()
    }

    /// Binds and returns the assigned port.
    func start() throws -> Void {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)

        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            throw LoopbackListenerError.couldNotBind(error.localizedDescription)
        }
        self.listener = listener

        // Both handlers must be installed *before* `start()`. NWListener refuses
        // to start without a connection handler and reports the refusal as a bare
        // EINVAL — which is what broke the Gemini sign-in when this handler was
        // attached after the listener had already reported ready.
        let classify = classify
        let requestBox = requestBox
        listener.newConnectionHandler = { connection in
            connection.start(queue: .main)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
                // A speculative preconnect carries no bytes at all; close it and
                // carry on rather than treating silence as an answer.
                guard let data, !data.isEmpty, let text = String(data: data, encoding: .utf8) else {
                    connection.cancel()
                    return
                }
                let outcome = classify(text)
                Self.reply(on: connection, page: outcome.page)
                if case .accept = outcome { requestBox.resume(returning: text) }
            }
        }

        let portBox = portBox
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                guard let port = listener.port?.rawValue else {
                    portBox.resume(throwing: LoopbackListenerError.noPortAssigned)
                    return
                }
                portBox.resume(returning: port)
            case let .failed(error):
                // Resolve both waits: a listener that dies after handing back its
                // port would otherwise leave the caller waiting out its timeout.
                portBox.resume(throwing: LoopbackListenerError.couldNotBind(error.localizedDescription))
                requestBox.resume(throwing: LoopbackListenerError.couldNotBind(error.localizedDescription))
            case .cancelled:
                portBox.resume(throwing: LoopbackListenerError.cancelled)
                requestBox.resume(throwing: LoopbackListenerError.cancelled)
            default:
                break
            }
        }

        listener.start(queue: .main)
    }

    /// The port the system assigned, once the listener is ready.
    func port() async throws -> UInt16 {
        try await portBox.value()
    }

    /// The first *accepted* request. Anything the classifier ignores — favicon
    /// fetches, preconnects, a mismatched state — is answered and skipped over.
    func nextRequest() async throws -> String {
        try await requestBox.value()
    }

    /// Abandons the wait with a caller-supplied reason, e.g. a timeout.
    func fail(_ error: Error) {
        requestBox.resume(throwing: error)
        cancel()
    }

    func cancel() {
        listener?.cancel()
        listener = nil
    }

    nonisolated private static func reply(on connection: NWConnection, page: LoopbackPage) {
        let body = """
        <!doctype html><meta charset="utf-8"><title>\(page.title)</title>
        <body style="font:15px -apple-system,system-ui,sans-serif;margin:0;display:grid;place-items:center;height:100vh">
        <div style="text-align:center;max-width:26rem;padding:2rem">
        <h1 style="font-size:1.25rem;margin:0 0 .5rem">\(page.title)</h1>
        <p style="margin:0;opacity:.7">\(page.detail)</p></div>
        """
        let response = """
        HTTP/1.1 \(page.status)\r
        Content-Type: text/html; charset=utf-8\r
        Content-Length: \(body.utf8.count)\r
        Connection: close\r
        \r
        \(body)
        """
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

/// A one-shot awaitable result, settled by whichever of the listener callbacks,
/// the caller or a timeout gets there first. Resolving before anyone is waiting
/// is fine — the result is held until it is asked for.
final class Once<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var settled: Result<Value, Error>?

    func value() async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let settled {
                lock.unlock()
                continuation.resume(with: settled)
                return
            }
            self.continuation = continuation
            lock.unlock()
        }
    }

    func resume(returning value: Value) { resume(with: .success(value)) }
    func resume(throwing error: Error) { resume(with: .failure(error)) }

    private func resume(with result: Result<Value, Error>) {
        lock.lock()
        guard settled == nil else { return lock.unlock() }
        settled = result
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}
