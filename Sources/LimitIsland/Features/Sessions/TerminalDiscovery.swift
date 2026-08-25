import AppKit
import Foundation

/// Finds the terminal hosting a live CLI process before it identifies itself.
/// `ps` supplies the tty and ancestry; `lsof` is used only for candidate agent
/// processes to disambiguate simultaneous sessions in different projects.
enum TerminalDiscovery {
    private struct ProcessRow {
        let pid: Int32
        let parent: Int32
        let tty: String?
        let command: String
    }

    /// The terminal hosting the one live `name` process working in `directory`.
    /// Ambiguity is answered with nothing: two agents in the same directory cannot
    /// be told apart from the outside, and guessing would point a jump at the wrong
    /// tab.
    static func cli(named name: String, in directory: String) -> TerminalRef? {
        let candidates = processRows().filter {
            isCLI($0.command, named: name) &&
            workingDirectory(of: $0.pid) == directory
        }
        guard candidates.count == 1, let process = candidates.first else { return nil }
        return terminal(of: process, workingDirectory: directory)
    }

    /// Every live process that *is* `name`, with the directory it is working in.
    ///
    /// Unlike `cli(named:in:)` this does not insist on a unique process per
    /// directory: it is for callers that already know which session a process
    /// belongs to — see `GeminiSessionAdopter`, which reads that from the process
    /// itself — and so have no ambiguity to protect against.
    static func liveCLIs(named name: String) -> [(pid: Int32, directory: String, terminal: TerminalRef)] {
        processRows()
            .filter { isCLI($0.command, named: name) }
            .compactMap { process in
                guard let directory = workingDirectory(of: process.pid),
                      let terminal = terminal(of: process, workingDirectory: directory) else { return nil }
                return (process.pid, directory, terminal)
            }
    }

    private static func terminal(of process: ProcessRow, workingDirectory directory: String) -> TerminalRef? {
        let byPID = Dictionary(processRows().map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        var chain: [Int32] = []
        var cursor: Int32? = process.pid
        for _ in 0..<24 {
            guard let pid = cursor, pid > 1 else { break }
            chain.append(pid)
            cursor = byPID[pid]?.parent
        }
        let program = chain.lazy.compactMap { pid -> String? in
            guard let app = NSRunningApplication(processIdentifier: pid),
                  app.activationPolicy == .regular else { return nil }
            switch app.bundleIdentifier {
            case "com.apple.Terminal": return "Apple_Terminal"
            case "com.googlecode.iterm2": return "iTerm.app"
            default: return app.bundleURL?.deletingPathExtension().lastPathComponent
            }
        }.first
        return TerminalRef(program: program, tty: process.tty, workingDirectory: directory,
                           agentPID: process.pid, pids: chain)
    }

    static func enriched(_ terminal: TerminalRef) -> TerminalRef {
        guard terminal.tty == nil, let pid = terminal.agentPID,
              let tty = processRows().first(where: { $0.pid == pid })?.tty else { return terminal }
        var result = terminal
        result.tty = tty
        return result
    }

    /// Startup replay gate. Prefer the UUID visible in a `codex resume` command;
    /// otherwise accept only a single live Codex process in the rollout's cwd.
    static func hasLiveCodexRollout(_ url: URL) -> Bool {
        guard let sessionID = CodexSessionWatcher.sessionID(fromFileName: url) else { return false }
        let rows = processRows().filter { isCLI($0.command, named: "codex") }
        if rows.contains(where: { $0.command.contains(sessionID) }) { return true }
        guard let directory = rolloutDirectory(in: url) else { return false }
        return rows.filter { workingDirectory(of: $0.pid) == directory }.count == 1
    }

    private static func rolloutDirectory(in url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 64 * 1024), !data.isEmpty else { return nil }
        for line in data.split(separator: 0x0A) {
            guard case let .started(_, directory, source)? = CodexRolloutParser.record(from: Data(line)),
                  source != .subagent else { continue }
            return directory
        }
        return nil
    }

    /// The executable must *be* the CLI, not merely mention it. This is what excludes
    /// `codex-code-mode-host` children, which share the cwd and tty with the real CLI
    /// and previously made every lookup look ambiguous.
    private static func isCLI(_ command: String, named name: String) -> Bool {
        let executable = command.split(separator: " ", maxSplits: 1).first.map(String.init) ?? command
        return (executable as NSString).lastPathComponent == name
    }

    nonisolated static func isProcessAlive(_ pid: Int32) -> Bool {
        // Signal zero changes nothing. EPERM still means the process exists.
        kill(pid, 0) == 0 || errno == EPERM
    }

    /// One `ps` is ~30 ms, and a single jump asks for the table several times over.
    /// Two seconds is far shorter than any session's lifetime and far longer than one
    /// burst of lookups.
    private static let snapshotLifetime: TimeInterval = 2

    private final class Snapshot: @unchecked Sendable {
        private let lock = NSLock()
        private var rows: [ProcessRow] = []
        private var takenAt = Date.distantPast

        func rows(_ read: () -> [ProcessRow]) -> [ProcessRow] {
            lock.lock()
            defer { lock.unlock() }
            if Date.now.timeIntervalSince(takenAt) < TerminalDiscovery.snapshotLifetime { return rows }
            rows = read()
            takenAt = .now
            return rows
        }
    }

    private static let snapshot = Snapshot()

    private static func processRows() -> [ProcessRow] {
        snapshot.rows(readProcessRows)
    }

    private static func readProcessRows() -> [ProcessRow] {
        guard let output = run("/bin/ps", ["-axo", "pid=,ppid=,tty=,command="]) else { return [] }
        return output.split(separator: "\n").compactMap { line in
            let fields = line.split(maxSplits: 3, whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count == 4, let pid = Int32(fields[0]), let parent = Int32(fields[1]) else { return nil }
            let tty = fields[2] == "??" ? nil : "/dev/\(fields[2])"
            return ProcessRow(pid: pid, parent: parent, tty: tty, command: String(fields[3]))
        }
    }

    private static func workingDirectory(of pid: Int32) -> String? {
        guard let output = run("/usr/sbin/lsof", ["-a", "-p", String(pid), "-d", "cwd", "-Fn"]) else { return nil }
        return output.split(separator: "\n").first(where: { $0.first == "n" }).map { String($0.dropFirst()) }
    }

    /// Every regular file this process has open. Used to ask a process which session
    /// it is running, where the process itself is the only honest source — see
    /// `GeminiSessionAdopter`.
    static func openFiles(of pid: Int32) -> [String] {
        guard let output = run("/usr/sbin/lsof", ["-a", "-p", String(pid), "-Fn"]) else { return [] }
        return output
            .split(separator: "\n")
            .filter { $0.first == "n" }
            .map { String($0.dropFirst()) }
    }

    private static func run(_ path: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        let errors = Pipe()
        process.standardOutput = pipe
        process.standardError = errors
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        // Drained, not ignored: a child that fills the stderr pipe blocks forever,
        // and `waitUntilExit` would then never return.
        _ = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
