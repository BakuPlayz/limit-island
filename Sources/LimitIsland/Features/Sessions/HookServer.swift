import Darwin
import Foundation

/// Listens on the Unix socket the hook helper connects to.
///
/// Deliberately POSIX sockets rather than `Network.framework`: the thing on the
/// other end is a short-lived process that is holding up someone's coding agent, so
/// the accept-read-reply-close path should be as few moving parts as possible, with
/// framing we control outright.
///
/// Threading: the listener and its per-connection reads live on a private queue, and
/// only the decoded event crosses onto the main actor. A connection blocks its own
/// worker thread while a human decides — that is what the CLI is waiting for — so
/// connections are served on a concurrent queue and never on the main one.
final class HookServer: @unchecked Sendable {
    /// Answers a hook event. Returning `nil` means "no opinion".
    typealias Handler = @Sendable (HookEvent) async -> (HookReply, String?)

    static var socketURL: URL {
        HookServer.supportDirectory.appendingPathComponent("hook.sock")
    }

    static var supportDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/LimitIsland")
    }

    private let queue = DispatchQueue(label: "com.limitisland.hook-server", attributes: .concurrent)
    private let acceptQueue = DispatchQueue(label: "com.limitisland.hook-accept")
    private var listenerDescriptor: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private let handler: Handler

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    // MARK: - Lifecycle

    func start() throws {
        stop()
        let url = Self.socketURL
        try FileManager.default.createDirectory(
            at: Self.supportDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        // A socket file left behind by a crash is not reusable — bind() would fail
        // with EADDRINUSE against a path nothing is listening on.
        try? FileManager.default.removeItem(at: url)

        let path = url.path
        guard path.utf8.count < 104 else { throw HookServerError.pathTooLong(path) }

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw HookServerError.socket(errno) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            path.withCString { source in
                _ = strncpy(UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: CChar.self), source, 103)
            }
        }

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            close(descriptor)
            throw HookServerError.bind(errno)
        }
        // Only this user's processes may connect. The socket carries no secrets, but
        // anything that can reach it can answer a permission prompt.
        chmod(path, 0o600)

        guard listen(descriptor, 32) == 0 else {
            close(descriptor)
            throw HookServerError.listen(errno)
        }

        listenerDescriptor = descriptor
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: acceptQueue)
        source.setEventHandler { [weak self] in self?.acceptOne() }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        acceptSource = source
        Log.hooks.info("listening on \(path, privacy: .public)")
    }

    func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        listenerDescriptor = -1
        try? FileManager.default.removeItem(at: Self.socketURL)
    }

    // MARK: - Connections

    private func acceptOne() {
        let client = accept(listenerDescriptor, nil, nil)
        guard client >= 0 else { return }
        queue.async { [weak self] in
            self?.serve(client)
        }
    }

    private func serve(_ descriptor: Int32) {
        defer { close(descriptor) }
        // The helper already caps its own patience; this is the app's guard against
        // a connection that opens and then says nothing.
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSignal: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))

        guard let line = readLine(from: descriptor),
              let event = try? JSONDecoder().decode(HookEvent.self, from: line) else {
            Log.hooks.error("could not decode a hook frame")
            return
        }

        // Most events are reports: the helper has already shut its write side and
        // is not reading a reply, so there is nothing to wait for. Hand them to the
        // main actor and let this thread go. Blocking here for every event parked a
        // worker per tool call, which on a busy agent is most of a thread pool.
        guard Self.blockingEvents.contains(event.event) else {
            Task { [handler] in _ = await handler(event) }
            // `defer` closes the socket on the way out. The helper has already
            // stopped writing and never reads for these, so it sees a clean close.
            return
        }

        // A decision, though, is exactly what the CLI is holding for. Bridge back
        // into structured concurrency and block this worker until it arrives.
        let semaphore = DispatchSemaphore(value: 0)
        // The box is safe because the semaphore orders the two accesses: nothing
        // reads the answer until the task has finished writing it and signalled.
        let box = AnswerBox()
        Task { [handler] in
            box.answer = await handler(event)
            semaphore.signal()
        }
        semaphore.wait()

        let (reply, reason) = box.answer
        var response = Data(reply.serialised(reason: reason).utf8)
        response.append(0x0A)
        _ = response.withUnsafeBytes { buffer in
            send(descriptor, buffer.baseAddress, buffer.count, 0)
        }
    }

    /// Events where the helper waits for a reply. Must agree with the helper's own
    /// list in `Sources/LimitIslandHook/main.swift`; `HookProtocolTests` checks it.
    static let blockingEvents: Set<String> = ["PreToolUse"]

    /// Reads up to the first newline. Frames are one line, so anything after it is
    /// a protocol error and discarded.
    private func readLine(from descriptor: Int32) -> Data? {
        var accumulated = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while accumulated.count < 4 * 1024 * 1024 {
            let read = recv(descriptor, &buffer, buffer.count, 0)
            if read <= 0 { break }
            accumulated.append(contentsOf: buffer[0..<read])
            if let newline = accumulated.firstIndex(of: 0x0A) {
                return accumulated[accumulated.startIndex..<newline]
            }
        }
        // The helper shuts down its write side after sending, so a frame with no
        // trailing newline still arrives complete.
        return accumulated.isEmpty ? nil : accumulated
    }
}

/// Hands one answer from the handler task back to the blocked connection thread.
/// Ordered by the semaphore around it, never accessed concurrently.
private final class AnswerBox: @unchecked Sendable {
    var answer: (HookReply, String?) = (.noOpinion, nil)
}

enum HookServerError: Error, CustomStringConvertible {
    case pathTooLong(String)
    case socket(Int32)
    case bind(Int32)
    case listen(Int32)

    var description: String {
        switch self {
        case let .pathTooLong(path): "socket path is too long for AF_UNIX: \(path)"
        case let .socket(code): "socket() failed: \(String(cString: strerror(code)))"
        case let .bind(code): "bind() failed: \(String(cString: strerror(code)))"
        case let .listen(code): "listen() failed: \(String(cString: strerror(code)))"
        }
    }
}
