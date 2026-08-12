import AppKit
import Foundation

enum JumpResolution: Equatable {
    case jumped
    case choose([TerminalDestination])
    case automationPermission(terminal: String)
    case setupRequired(terminal: String)
    /// The exact tab was unavailable, but the owning terminal was brought forward.
    case applicationFallback(terminal: String)
    case stale
}

/// Resolves and selects the exact terminal surface where possible. Every path
/// returns a result so the island closes only after a real jump succeeds.
@MainActor
enum TerminalJumper {
    static func jump(to session: AgentSession) -> JumpResolution {
        guard let terminal = session.terminal else { return .stale }

        if let chosen = session.selectedDestination {
            return jump(to: chosen, fallback: terminal)
        }

        if let pane = terminal.tmuxPane {
            guard selectTmuxPane(pane, socket: terminal.tmuxSocket) else { return activateTerminalApplication(terminal) }
            return activateOwningApplication(terminal)
        }

        switch normalized(terminal.program) {
        case "iterm":
            if let id = terminal.iTermSessionID {
                return exactOrApplication(selectITerm(id: id), terminal: terminal, name: "iTerm")
            }
            if let tty = terminal.tty {
                return exactOrApplication(selectITerm(tty: tty), terminal: terminal, name: "iTerm")
            }
            return activateTerminalApplication(terminal)
        case "terminal":
            guard let tty = terminal.tty else { return activateTerminalApplication(terminal) }
            return exactOrApplication(selectTerminalApp(tty: tty), terminal: terminal, name: "Terminal")
        case "ghostty":
            return resolveGhostty(terminal)
        default:
            if let id = terminal.kittyWindowID, let socket = terminal.kittyListenOn {
                guard let executable = tool("kitten", fallback: "/Applications/kitty.app/Contents/MacOS/kitten") else {
                    return .setupRequired(terminal: "kitty")
                }
                return commandSucceeded(executable, ["@", "--to", socket, "focus-window", "--match", "id:\(id)"])
                    ? .jumped : activateTerminalApplication(terminal)
            }
            if let pane = terminal.weztermPane {
                guard let executable = tool("wezterm", fallback: "/Applications/WezTerm.app/Contents/MacOS/wezterm") else {
                    return activateOwningApplication(terminal)
                }
                return commandSucceeded(executable, ["cli", "activate-pane", "--pane-id", pane])
                    ? .jumped : activateTerminalApplication(terminal)
            }
            if normalized(terminal.program).contains("kitty") { return .setupRequired(terminal: "kitty") }
            return activateOwningApplication(terminal)
        }
    }

    private static func jump(to destination: TerminalDestination, fallback terminal: TerminalRef) -> JumpResolution {
        switch destination.kind {
        case .ghostty:
            let result = runAppleScript("""
            tell application "Ghostty"
                repeat with t in terminals
                    if id of t as text is "\(escaped(destination.stableID))" then
                        focus t
                        return "ok"
                    end if
                end repeat
            end tell
            return "miss"
            """)
            return exactOrApplication(result, terminal: terminal, name: "Ghostty")
        }
    }

    private static func resolveGhostty(_ terminal: TerminalRef) -> JumpResolution {
        guard let directory = terminal.workingDirectory else { return activateOwningApplication(terminal) }
        let script = """
        set output to ""
        tell application "Ghostty"
            repeat with t in terminals
                if working directory of t is "\(escaped(directory))" then
                    set output to output & (id of t as text) & "\t" & (name of t as text) & linefeed
                end if
            end repeat
        end tell
        return output
        """
        let result = runAppleScript(script)
        if result.permissionDenied { return .automationPermission(terminal: "Ghostty") }
        guard result.succeeded else { return activateOwningApplication(terminal) }
        let matches = result.output.split(separator: "\n").compactMap { line -> TerminalDestination? in
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard let id = parts.first, !id.isEmpty else { return nil }
            return TerminalDestination(kind: .ghostty, stableID: String(id), terminalName: "Ghostty",
                                       title: parts.count > 1 ? String(parts[1]) : directory,
                                       workingDirectory: directory)
        }
        if matches.count == 1, let match = matches.first { return jump(to: match, fallback: terminal) }
        if matches.count > 1 { return .choose(matches) }
        return activateTerminalApplication(terminal)
    }

    private static func selectITerm(id: String) -> CommandResult {
        let uuid = id.split(separator: ":").last.map(String.init) ?? id
        return runAppleScript(iTermScript(property: "id", value: uuid))
    }

    private static func selectITerm(tty: String) -> CommandResult {
        runAppleScript(iTermScript(property: "tty", value: tty))
    }

    private static func iTermScript(property: String, value: String) -> String {
        """
        tell application "iTerm"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if \(property) of s is "\(escaped(value))" then
                            select w
                            select t
                            select s
                            activate
                            return "ok"
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        return "miss"
        """
    }

    private static func selectTerminalApp(tty: String) -> CommandResult {
        runAppleScript("""
        tell application "Terminal"
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is "\(escaped(tty))" then
                        set selected of t to true
                        set index of w to 1
                        activate
                        return "ok"
                    end if
                end repeat
            end repeat
        end tell
        return "miss"
        """)
    }

    private static func selectTmuxPane(_ pane: String, socket: String?) -> Bool {
        guard let executable = tool("tmux", fallback: "/usr/local/bin/tmux") else { return false }
        var prefix: [String] = []
        if let socket, !socket.isEmpty { prefix = ["-S", socket] }
        return commandSucceeded(executable, prefix + ["select-window", "-t", pane]) &&
            commandSucceeded(executable, prefix + ["select-pane", "-t", pane])
    }

    private static func activateOwningApplication(_ terminal: TerminalRef) -> JumpResolution {
        for pid in terminal.pids {
            guard let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular else { continue }
            app.activate(options: [.activateAllWindows])
            let exact = ["terminal", "iterm", "ghostty"].contains(normalized(terminal.program))
            return exact ? .jumped : .applicationFallback(terminal: terminal.displayName)
        }
        return activateTerminalApplication(terminal)
    }

    /// Process ancestry is the best route, but a tab can disappear while its app
    /// remains open. Resolve by bundle id/name next and launch the known terminal
    /// as a last resort, so clicking an agent always takes the user somewhere useful.
    private static func activateTerminalApplication(_ terminal: TerminalRef) -> JumpResolution {
        let identity = appIdentity(for: terminal.program)
        if let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == identity.bundleID || $0.localizedName == identity.name
        }) {
            app.activate(options: [.activateAllWindows])
            return .applicationFallback(terminal: identity.name)
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identity.bundleID) {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
            return .applicationFallback(terminal: identity.name)
        }
        return .stale
    }

    private static func appIdentity(for program: String?) -> (bundleID: String, name: String) {
        switch normalized(program) {
        case "terminal": ("com.apple.Terminal", "Terminal")
        case "iterm": ("com.googlecode.iterm2", "iTerm")
        case "ghostty": ("com.mitchellh.ghostty", "Ghostty")
        case let value where value.contains("wezterm"): ("com.github.wez.wezterm", "WezTerm")
        case let value where value.contains("kitty"): ("net.kovidgoyal.kitty", "kitty")
        case let value where value.contains("warp"): ("dev.warp.Warp-Stable", "Warp")
        case let value where value.contains("alacritty"): ("org.alacritty", "Alacritty")
        case let value where value.contains("cursor"): ("com.todesktop.230313mzl4w4u92", "Cursor")
        case let value where value.contains("vscode") || value.contains("code"): ("com.microsoft.VSCode", "Visual Studio Code")
        case let value where value.contains("zed"): ("dev.zed.Zed", "Zed")
        default: ("", terminalName(program))
        }
    }

    private static func terminalName(_ program: String?) -> String {
        program?.replacingOccurrences(of: ".app", with: "") ?? "Terminal"
    }

    private static func normalized(_ program: String?) -> String {
        let value = program?.lowercased() ?? ""
        if value.contains("iterm") { return "iterm" }
        if value.contains("apple_terminal") || value == "terminal" { return "terminal" }
        if value.contains("ghostty") { return "ghostty" }
        return value
    }

    private struct CommandResult {
        let status: Int32
        let output: String
        let error: String
        var succeeded: Bool { status == 0 }
        var permissionDenied: Bool {
            error.localizedCaseInsensitiveContains("not authorized") ||
            error.localizedCaseInsensitiveContains("not permitted") || status == 1743
        }
    }

    private static func exactOrApplication(_ result: CommandResult, terminal: TerminalRef, name: String) -> JumpResolution {
        if result.permissionDenied {
            _ = activateTerminalApplication(terminal)
            return .automationPermission(terminal: name)
        }
        return result.succeeded && result.output == "ok" ? .jumped : activateTerminalApplication(terminal)
    }

    private static func runAppleScript(_ source: String) -> CommandResult {
        run("/usr/bin/osascript", ["-e", source])
    }

    private static func commandSucceeded(_ path: String, _ arguments: [String]) -> Bool {
        run(path, arguments).succeeded
    }

    private static func run(_ path: String, _ arguments: [String]) -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        do { try process.run() } catch { return CommandResult(status: -1, output: "", error: error.localizedDescription) }
        let out = stdout.fileHandleForReading.readDataToEndOfFile()
        let err = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return CommandResult(status: process.terminationStatus,
                             output: String(data: out, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                             error: String(data: err, encoding: .utf8) ?? "")
    }

    private static func tool(_ name: String, fallback: String) -> String? {
        let candidates = ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)", fallback]
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
    }

    static func openAutomationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") else { return }
        NSWorkspace.shared.open(url)
    }

    private static func escaped(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
