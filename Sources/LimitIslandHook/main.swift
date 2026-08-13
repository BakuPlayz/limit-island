import Darwin
import Foundation

// The hook helper. Claude Code (and Codex, via `notify`) runs this once per event,
// with the event payload on stdin.
//
// One rule outranks every feature here: **never break the CLI**. If Limit Island is
// not running, if the socket is stale, if anything at all goes wrong, this exits 0
// having printed nothing, and the CLI behaves exactly as if the hook did not exist.
// Every failure path below is written to that standard, which is also why there is
// no logging and no error output — stderr from a hook is surfaced to the user.

let arguments = CommandLine.arguments
let eventFromArgv = arguments.count > 1 ? arguments[1] : nil
let cli = arguments.count > 2 ? arguments[2] : "claude"

/// Events where the CLI is waiting on our answer, so we hold the pipe open.
/// Everything else is fire-and-forget: report and get out of the way.
let blockingEvents: Set<String> = ["PreToolUse", "PermissionRequest"]

// MARK: - Input

// Claude Code passes its payload on stdin. Codex's `notify` passes JSON as a
// trailing argument instead, and never reads a reply — so reading stdin there would
// block until Codex closed the pipe.
let isCodexNotify = eventFromArgv == "notify"
let payload: [String: Any]
if isCodexNotify {
    let argument = arguments.count > 3 ? arguments[3] : (arguments.last ?? "{}")
    payload = (try? JSONSerialization.jsonObject(with: Data(argument.utf8))) as? [String: Any] ?? [:]
} else {
    let stdinData = FileHandle.standardInput.readDataToEndOfFile()
    payload = (try? JSONSerialization.jsonObject(with: stdinData)) as? [String: Any] ?? [:]
}
let event = eventFromArgv ?? (payload["hook_event_name"] as? String) ?? "Unknown"

// MARK: - Context the app cannot see from its own process

/// The terminal-identifying variables the CLI inherited. The app turns these into a
/// precise "jump to this tab" target; without them it can only raise an app.
let interestingVariables = [
    "TERM_PROGRAM", "TERM_PROGRAM_VERSION", "TERM_SESSION_ID", "TERM",
    "ITERM_SESSION_ID", "TMUX", "TMUX_PANE",
    "WEZTERM_PANE", "WEZTERM_UNIX_SOCKET",
    "KITTY_WINDOW_ID", "KITTY_LISTEN_ON",
    "WINDOWID", "ALACRITTY_WINDOW_ID", "GHOSTTY_RESOURCES_DIR",
    "ZELLIJ", "ZELLIJ_SESSION_NAME",
    "VSCODE_INJECTION", "TERMINAL_EMULATOR"
]

let environment = ProcessInfo.processInfo.environment
var capturedEnvironment: [String: String] = [:]
for name in interestingVariables {
    if let value = environment[name] { capturedEnvironment[name] = value }
}

/// stdin is the hook payload pipe, so the controlling terminal has to be read from
/// another descriptor. stderr is inherited straight from the CLI, which makes it the
/// reliable one — Terminal.app tabs are addressable by tty and nothing else.
func controllingTTY() -> String? {
    for descriptor in [Int32(2), Int32(1)] {
        guard isatty(descriptor) == 1, let name = ttyname(descriptor) else { continue }
        return String(cString: name)
    }
    return nil
}

/// The chain of parent processes up to launchd. The app resolves these to running
/// applications itself — `NSRunningApplication` is not available here, and the
/// short `p_comm` name a process reports is truncated to 16 characters and often
/// says "login" or "zsh" rather than which terminal is hosting them.
func ancestorProcessIDs() -> [Int32] {
    var chain: [Int32] = []
    var pid = getpid()
    // Bounded so a pathological process tree cannot spin here.
    for _ in 0..<24 {
        guard pid > 1 else { break }
        chain.append(pid)
        guard let parent = parentProcessID(of: pid), parent != pid else { break }
        pid = parent
    }
    return chain
}

func parentProcessID(of pid: Int32) -> Int32? {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    let result = sysctl(&name, u_int(name.count), &info, &size, nil, 0)
    guard result == 0, size > 0 else { return nil }
    return info.kp_eproc.e_ppid
}

// MARK: - Frame

let frame: [String: Any] = [
    "event": event,
    "cli": cli,
    "payload": payload,
    "env": capturedEnvironment,
    "pids": ancestorProcessIDs().map(Int.init),
    "tty": controllingTTY() ?? "",
    "sentAt": Date().timeIntervalSince1970
]

guard let frameData = try? JSONSerialization.data(withJSONObject: frame) else {
    exit(0)
}

// MARK: - Transport

func socketPath() -> String {
    if let override = environment["LIMIT_ISLAND_SOCKET"], !override.isEmpty { return override }
    let home = environment["HOME"] ?? NSHomeDirectory()
    return "\(home)/Library/Application Support/LimitIsland/hook.sock"
}

/// Sends the frame and, for a blocking event, returns whatever the app replies.
/// Returns nil on any failure — which the caller treats as "say nothing".
func exchange(_ data: Data, waitingForReply: Bool) -> String? {
    let path = socketPath()
    guard path.utf8.count < 104 else { return nil }

    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { return nil }
    defer { close(descriptor) }

    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    _ = withUnsafeMutablePointer(to: &address.sun_path) { pointer in
        path.withCString { source in
            strncpy(UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: CChar.self), source, 103)
        }
    }
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

    // Connecting is the step that fails when the app is not running, and it is
    // where the whole design earns its keep: no listener, no delay, no output.
    let connected = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
            connect(descriptor, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard connected == 0 else { return nil }

    // A non-blocking event must not delay the CLI even by a round trip, so both
    // directions get a short ceiling. A blocking one waits for a human, but still
    // less than the hook timeout configured in settings.json — expiring here means
    // the CLI falls back to its own prompt rather than being cut off mid-decision.
    var timeout = timeval(tv_sec: waitingForReply ? 540 : 2, tv_usec: 0)
    setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    var sendTimeout = timeval(tv_sec: 2, tv_usec: 0)
    setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &sendTimeout, socklen_t(MemoryLayout<timeval>.size))
    // Without this a closed socket raises SIGPIPE and kills the hook — which the
    // CLI sees as a crashed hook rather than a quiet no-op.
    var noSignal: Int32 = 1
    setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))

    var outgoing = data
    outgoing.append(0x0A) // newline-delimited frames
    let written: Int = outgoing.withUnsafeBytes { buffer in
        var offset = 0
        while offset < buffer.count {
            let sent = send(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset, 0)
            if sent <= 0 { return -1 }
            offset += sent
        }
        return offset
    }
    guard written > 0 else { return nil }
    shutdown(descriptor, SHUT_WR)

    guard waitingForReply else { return nil }

    var response = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
        let read = recv(descriptor, &buffer, buffer.count, 0)
        if read <= 0 { break }
        response.append(contentsOf: buffer[0..<read])
        if response.last == 0x0A { break }
    }
    guard !response.isEmpty else { return nil }
    return String(data: response, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
}

let reply = exchange(frameData, waitingForReply: blockingEvents.contains(event))

// The app answers with the exact JSON the CLI expects on stdout, or with an empty
// object when it has no opinion. Anything unparseable is treated as no opinion:
// printing a malformed decision would be worse than printing nothing.
if let reply,
   !reply.isEmpty,
   let data = reply.data(using: .utf8),
   let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
   !object.isEmpty {
    FileHandle.standardOutput.write(Data(reply.utf8))
}

exit(0)
