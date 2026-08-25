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
///
/// Every subprocess here — `ps`, `lsof`, `osascript` — runs off the main thread and
/// is awaited. A jump used to be a handful of `waitUntilExit()` calls inside a tap
/// gesture, which froze the whole UI for as long as the terminal took to answer, and
/// for the length of the Automation permission prompt the first time.
@MainActor
enum TerminalJumper {
    /// Answers a recognized Codex single-choice picker. The exact destination is
    /// focused first; failure to prove it aborts without emitting a key.
    static func answerCodexChoice(_ option: Int, in session: AgentSession) async -> JumpResolution {
        await answerCodexSelection([option], multiSelect: false, in: session) ? .jumped : .stale
    }

    /// Sends one complete Codex picker answer to the exact terminal surface. A
    /// multi-select picker toggles each chosen row before submitting; a normal
    /// picker moves to its chosen row and submits directly.
    static func answerCodexSelection(
        _ options: [Int], multiSelect: Bool, in session: AgentSession
    ) async -> Bool {
        let choices = Array(Set(options)).sorted()
        guard !choices.isEmpty, choices.allSatisfy({ $0 >= 0 }),
              let terminal = session.terminal else { return false }
        let focus = await jump(to: session)
        guard focus == .jumped else { return false }
        // Terminal and iTerm are answered by aiming key codes at whatever is
        // frontmost, and `jump` returning success is not the same as the terminal
        // having won the activation race. `sendPrompt` has always proved this before
        // typing; a picker answer is arrow keys and a Return, which is no safer to
        // deliver into someone's editor.
        if needsFocusToSend(terminal), !isFrontmost(terminal) { return false }

        let keys = pickerKeys(choices, multiSelect: multiSelect)

        if let pane = terminal.tmuxPane {
            guard let executable = tool("tmux", fallback: "/usr/local/bin/tmux") else { return false }
            var prefix: [String] = []
            if let socket = terminal.tmuxSocket { prefix = ["-S", socket] }
            for key in keys {
                guard await commandSucceeded(executable, prefix + ["send-keys", "-t", pane, key.tmuxName])
                else { return false }
            }
            return true
        }
        if let pane = terminal.weztermPane,
           let executable = tool("wezterm", fallback: "/Applications/WezTerm.app/Contents/MacOS/wezterm") {
            let text = keys.map(\.terminalText).joined()
            return await commandSucceeded(executable, ["cli", "send-text", "--no-paste", "--pane-id", pane, text])
        }
        if let id = terminal.kittyWindowID, let socket = terminal.kittyListenOn,
           let executable = tool("kitten", fallback: "/Applications/kitty.app/Contents/MacOS/kitten") {
            for key in keys {
                guard await commandSucceeded(
                    executable, ["@", "--to", socket, "send-key", "--match", "id:\(id)", key.kittyName]
                ) else { return false }
            }
            return true
        }
        if normalized(terminal.program) == "ghostty", let destination = session.selectedDestination {
            let strokes = keys.map { "send key \"\($0.ghosttyName)\" to t" }.joined(separator: "\n")
            let result = await runAppleScript("""
            tell application "Ghostty"
                repeat with t in terminals
                    if id of t as text is "\(escaped(destination.stableID))" then
                        focus t
                        \(strokes)
                        return "ok"
                    end if
                end repeat
            end tell
            return "miss"
            """)
            return result.succeeded && result.output == "ok"
        }

        // Terminal and iTerm have no targeted input API. Accessibility supplies
        // arrows only after the exact-tab jump above has made the terminal active.
        let appName = normalized(terminal.program) == "iterm" ? "iTerm" : "Terminal"
        let strokes = keys.map { "key code \($0.appleKeyCode)" }.joined(separator: "\n")
        let result = await runAppleScript("""
        tell application "System Events"
            if name of first application process whose frontmost is true is not "\(appName)" then return "miss"
            \(strokes)
        end tell
        return "ok"
        """)
        return result.succeeded && result.output == "ok"
    }

    /// Types a prompt into a session sitting idle at its composer.
    ///
    /// tmux, WezTerm and kitty address a pane directly, so nothing is taken from
    /// whatever the person is doing — which matters here in a way it does not for a
    /// picker answer, because this fires on a timer rather than on a click. The
    /// AppleScript backends have no targeted input at all, so those are focused
    /// first; `needsFocusToSend` lets the card say so before anyone agrees to it.
    static func sendPrompt(_ text: String, in session: AgentSession) async -> Bool {
        guard let terminal = session.terminal else { return false }
        if needsFocusToSend(terminal) {
            guard await jump(to: session) == .jumped else { return false }
            // `jump` reporting success is not the same as the terminal having won
            // the activation race, and this path types blind into whatever is
            // frontmost. Proving it first is the difference between resuming an
            // agent and typing a sentence into someone's editor.
            guard isFrontmost(terminal) else { return false }
        }
        return await sendLine(text, in: session)
    }

    /// Prefix rather than equality: `displayName` is what a person calls the app,
    /// and the running application answers with its version — "iTerm" against
    /// "iTerm2".
    private static func isFrontmost(_ terminal: TerminalRef) -> Bool {
        guard let running = NSWorkspace.shared.frontmostApplication?.localizedName else { return false }
        return running.lowercased().hasPrefix(terminal.displayName.lowercased())
    }

    /// Whether typing into this surface means bringing its terminal forward. The
    /// split is the same one `answerCodexSelection` encodes: a pane addressed by id
    /// over a control socket, or System Events aimed at whatever is frontmost.
    static func needsFocusToSend(_ terminal: TerminalRef) -> Bool {
        if terminal.tmuxPane != nil { return false }
        if terminal.weztermPane != nil { return false }
        if terminal.kittyWindowID != nil, terminal.kittyListenOn != nil { return false }
        return true
    }

    /// Types one line into the exact terminal surface and presses Return. Only ever
    /// called once the surface is known to be focused, or known not to need it.
    private static func sendLine(_ text: String, in session: AgentSession) async -> Bool {
        guard let terminal = session.terminal else { return false }

        if let pane = terminal.tmuxPane {
            guard let executable = tool("tmux", fallback: "/usr/local/bin/tmux") else { return false }
            let prefix = terminal.tmuxSocket.map { ["-S", $0] } ?? []
            guard await commandSucceeded(executable, prefix + ["send-keys", "-t", pane, "-l", "--", text])
            else { return false }
            return await commandSucceeded(executable, prefix + ["send-keys", "-t", pane, "Enter"])
        }
        if let pane = terminal.weztermPane,
           let executable = tool("wezterm", fallback: "/Applications/WezTerm.app/Contents/MacOS/wezterm") {
            return await commandSucceeded(
                executable, ["cli", "send-text", "--no-paste", "--pane-id", pane, text + "\r"]
            )
        }
        if let id = terminal.kittyWindowID, let socket = terminal.kittyListenOn,
           let executable = tool("kitten", fallback: "/Applications/kitty.app/Contents/MacOS/kitten") {
            guard await commandSucceeded(
                executable, ["@", "--to", socket, "send-text", "--match", "id:\(id)", "--", text]
            ) else { return false }
            return await commandSucceeded(
                executable, ["@", "--to", socket, "send-key", "--match", "id:\(id)", "enter"]
            )
        }

        // Everything else types through Accessibility, which needs the terminal
        // frontmost — which the selection that preceded this call made it.
        let result = await runAppleScript("""
        tell application "System Events"
            keystroke "\(escaped(text))"
            key code 36
        end tell
        return "ok"
        """)
        return result.succeeded && result.output == "ok"
    }

    private enum PickerKey {
        case down, toggle, submit
        var tmuxName: String { switch self { case .down: "Down"; case .toggle: "Space"; case .submit: "Enter" } }
        var kittyName: String { switch self { case .down: "down"; case .toggle: "space"; case .submit: "enter" } }
        var ghosttyName: String { switch self { case .down: "down"; case .toggle: "space"; case .submit: "enter" } }
        var terminalText: String { switch self { case .down: "\u{1B}[B"; case .toggle: " "; case .submit: "\r" } }
        var appleKeyCode: Int { switch self { case .down: 125; case .toggle: 49; case .submit: 36 } }
    }

    private static func pickerKeys(_ choices: [Int], multiSelect: Bool) -> [PickerKey] {
        guard multiSelect else { return Array(repeating: .down, count: choices[0]) + [.submit] }
        var keys: [PickerKey] = []
        var row = 0
        for choice in choices {
            keys += Array(repeating: .down, count: choice - row)
            keys.append(.toggle)
            row = choice
        }
        keys.append(.submit)
        return keys
    }
    static func jump(to session: AgentSession) async -> JumpResolution {
        guard let rawTerminal = session.terminal else { return .stale }
        let terminal = await Task.detached { TerminalDiscovery.enriched(rawTerminal) }.value

        if let chosen = session.selectedDestination {
            return await jump(to: chosen, fallback: terminal)
        }

        if let pane = terminal.tmuxPane {
            guard await selectTmuxPane(pane, socket: terminal.tmuxSocket) else {
                return activateTerminalApplication(terminal)
            }
            return activateOwningApplication(terminal)
        }

        switch normalized(terminal.program) {
        case "iterm":
            if let id = terminal.iTermSessionID {
                return exactOrApplication(await selectITerm(id: id), terminal: terminal, name: "iTerm")
            }
            if let tty = terminal.tty {
                return exactOrApplication(await selectITerm(tty: tty), terminal: terminal, name: "iTerm")
            }
            return activateTerminalApplication(terminal)
        case "terminal":
            guard let tty = terminal.tty else { return activateTerminalApplication(terminal) }
            return exactOrApplication(await selectTerminalApp(tty: tty), terminal: terminal, name: "Terminal")
        case "ghostty":
            return await resolveGhostty(terminal)
        default:
            if let id = terminal.kittyWindowID, let socket = terminal.kittyListenOn {
                guard let executable = tool("kitten", fallback: "/Applications/kitty.app/Contents/MacOS/kitten") else {
                    return .setupRequired(terminal: "kitty")
                }
                return await commandSucceeded(executable, ["@", "--to", socket, "focus-window", "--match", "id:\(id)"])
                    ? .jumped : activateTerminalApplication(terminal)
            }
            if let pane = terminal.weztermPane {
                guard let executable = tool("wezterm", fallback: "/Applications/WezTerm.app/Contents/MacOS/wezterm") else {
                    return activateOwningApplication(terminal)
                }
                return await commandSucceeded(executable, ["cli", "activate-pane", "--pane-id", pane])
                    ? .jumped : activateTerminalApplication(terminal)
            }
            if normalized(terminal.program).contains("kitty") { return .setupRequired(terminal: "kitty") }
            return activateOwningApplication(terminal)
        }
    }

    private static func jump(to destination: TerminalDestination, fallback terminal: TerminalRef) async -> JumpResolution {
        switch destination.kind {
        case .ghostty:
            let result = await runAppleScript("""
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

    private static func resolveGhostty(_ terminal: TerminalRef) async -> JumpResolution {
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
        let result = await runAppleScript(script)
        if result.permissionDenied { return .automationPermission(terminal: "Ghostty") }
        guard result.succeeded else { return activateOwningApplication(terminal) }
        let matches = result.output.split(separator: "\n").compactMap { line -> TerminalDestination? in
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard let id = parts.first, !id.isEmpty else { return nil }
            return TerminalDestination(kind: .ghostty, stableID: String(id), terminalName: "Ghostty",
                                       title: parts.count > 1 ? String(parts[1]) : directory,
                                       workingDirectory: directory)
        }
        if matches.count == 1, let match = matches.first { return await jump(to: match, fallback: terminal) }
        if matches.count > 1 { return .choose(matches) }
        return activateTerminalApplication(terminal)
    }

    private static func selectITerm(id: String) async -> CommandResult {
        let uuid = id.split(separator: ":").last.map(String.init) ?? id
        return await runAppleScript(iTermScript(property: "id", value: uuid))
    }

    private static func selectITerm(tty: String) async -> CommandResult {
        await runAppleScript(iTermScript(property: "tty", value: tty))
    }

    private nonisolated static func iTermScript(property: String, value: String) -> String {
        """
        tell application "iTerm"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if \(property) of s is "\(escaped(value))" then
                            try
                                set miniaturized of w to false
                            end try
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

    private static func selectTerminalApp(tty: String) async -> CommandResult {
        // `miniaturized` first: a window in the Dock is still a window the script can
        // select and index, so without this the jump reported success and nothing
        // came back on screen.
        await runAppleScript("""
        tell application "Terminal"
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is "\(escaped(tty))" then
                        try
                            set miniaturized of w to false
                        end try
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

    private static func selectTmuxPane(_ pane: String, socket: String?) async -> Bool {
        guard let executable = tool("tmux", fallback: "/usr/local/bin/tmux") else { return false }
        var prefix: [String] = []
        if let socket, !socket.isEmpty { prefix = ["-S", socket] }
        guard await commandSucceeded(executable, prefix + ["select-window", "-t", pane]) else { return false }
        return await commandSucceeded(executable, prefix + ["select-pane", "-t", pane])
    }

    private static func activateOwningApplication(_ terminal: TerminalRef) -> JumpResolution {
        for pid in terminal.pids {
            guard let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular else { continue }
            // Activation alone leaves a ⌘H-hidden app hidden: the app becomes active
            // with no window shown, which reads as the jump doing nothing.
            app.unhide()
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
            app.unhide()
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

    private static func runAppleScript(_ source: String) async -> CommandResult {
        await runOffMain("/usr/bin/osascript", ["-e", source])
    }

    private static func commandSucceeded(_ path: String, _ arguments: [String]) async -> Bool {
        await runOffMain(path, arguments).succeeded
    }

    /// The only way a subprocess is ever launched from here. `run` itself blocks
    /// until the child exits, which on the main thread is the whole UI.
    private static func runOffMain(_ path: String, _ arguments: [String]) async -> CommandResult {
        await Task.detached(priority: .userInitiated) { run(path, arguments) }.value
    }

    private nonisolated static func run(_ path: String, _ arguments: [String]) -> CommandResult {
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

    /// Where a CLI lives does not change between clicks, so the three `stat` calls
    /// are paid once per tool for the life of the app.
    private static var toolPaths: [String: String?] = [:]

    private static func tool(_ name: String, fallback: String) -> String? {
        if let known = toolPaths[name] { return known }
        let candidates = ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)", fallback]
        let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        toolPaths[name] = found
        return found
    }

    static func openAutomationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") else { return }
        NSWorkspace.shared.open(url)
    }

    private nonisolated static func escaped(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
