import AppKit
import Foundation

/// Finds the terminal hosting a live Codex process before its notify callback runs.
/// `ps` supplies the tty and ancestry; `lsof` is used only for candidate Codex
/// processes to disambiguate simultaneous sessions in different projects.
enum TerminalDiscovery {
    private struct ProcessRow {
        let pid: Int32
        let parent: Int32
        let tty: String?
        let command: String
    }

    static func codex(in directory: String) -> TerminalRef? {
        let rows = processRows()
        let byPID = Dictionary(uniqueKeysWithValues: rows.map { ($0.pid, $0) })
        let candidates = rows.filter {
            isCodexCLI($0.command) &&
            workingDirectory(of: $0.pid) == directory
        }
        guard candidates.count == 1, let process = candidates.first else { return nil }

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
        let rows = processRows().filter { isCodexCLI($0.command) }
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

    /// Exclude `codex-code-mode-host` children. They share the cwd and tty with
    /// the real CLI and previously made every lookup look ambiguous.
    private static func isCodexCLI(_ command: String) -> Bool {
        let executable = command.split(separator: " ", maxSplits: 1).first.map(String.init) ?? command
        return (executable as NSString).lastPathComponent == "codex"
    }

    nonisolated static func isProcessAlive(_ pid: Int32) -> Bool {
        // Signal zero changes nothing. EPERM still means the process exists.
        kill(pid, 0) == 0 || errno == EPERM
    }

    private static func processRows() -> [ProcessRow] {
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

    private static func run(_ path: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
