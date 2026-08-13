import Foundation

/// What an agent is doing right now, as far as its hooks have told us.
enum SessionActivity: Equatable, Sendable {
    case starting
    /// Between a prompt and the first tool call, or between tool calls.
    case thinking
    /// A tool is running; the string is the short human description in the panel.
    case running(String)
    /// The CLI is waiting on the person, and we are showing them the question.
    case awaitingDecision
    /// The CLI is waiting on the person, but in its own terminal UI.
    case waitingInTerminal(String)
    case done

    var isWaiting: Bool {
        switch self {
        case .awaitingDecision, .waitingInTerminal: true
        default: false
        }
    }

    /// The line under the title in the panel. `nil` where the status dot says it.
    var detail: String? {
        switch self {
        case .starting: nil
        case .thinking: "Thinking…"
        case let .running(what): what
        case .awaitingDecision: "Waiting for you"
        case let .waitingInTerminal(what): what
        case .done: "Done — click to jump"
        }
    }
}

/// How to get back to the terminal this session is running in.
///
/// Everything here comes from the environment the CLI inherited, captured by the
/// hook helper. The app cannot read another process's environment, which is why
/// this is collected at hook time rather than looked up on demand.
struct TerminalRef: Equatable, Sendable, Codable {
    /// `TERM_PROGRAM`, normalised: `iTerm.app`, `Apple_Terminal`, `ghostty`, …
    var program: String?
    var iTermSessionID: String?
    var terminalSessionID: String?
    var tmuxPane: String?
    var tmuxSocket: String?
    var weztermPane: String?
    var kittyWindowID: String?
    var kittyListenOn: String?
    var tty: String?
    /// Full path, retained for terminal APIs such as Ghostty that expose a surface
    /// by working directory rather than by its child tty.
    var workingDirectory: String?
    /// The CLI process itself. Unlike the full ancestry chain, this becomes dead
    /// when the agent is actually closed while its terminal application stays up.
    var agentPID: Int32?
    /// Process chain from the hook up to launchd, nearest first.
    var pids: [Int32] = []

    init(event: HookEvent) {
        let environment = event.env
        program = environment["TERM_PROGRAM"]
        iTermSessionID = environment["ITERM_SESSION_ID"]
        terminalSessionID = environment["TERM_SESSION_ID"]
        tmuxPane = environment["TMUX_PANE"]
        // $TMUX is "socket,pid,session"; only the socket path is useful to us.
        tmuxSocket = environment["TMUX"]?.split(separator: ",").first.map(String.init)
        weztermPane = environment["WEZTERM_PANE"]
        kittyWindowID = environment["KITTY_WINDOW_ID"]
        kittyListenOn = environment["KITTY_LISTEN_ON"]
        tty = event.tty.isEmpty ? nil : event.tty
        workingDirectory = event.workingDirectory
        pids = event.pids
        // The helper is first and its parent is the CLI that launched the hook.
        agentPID = event.pids.dropFirst().first
    }

    init(program: String?, tty: String?, workingDirectory: String?, agentPID: Int32?, pids: [Int32]) {
        self.program = program
        self.tty = tty
        self.workingDirectory = workingDirectory
        self.agentPID = agentPID
        self.pids = pids
    }

    /// Short label for the badge beside the provider, matching what a person calls
    /// the app rather than what it calls itself.
    var displayName: String {
        if tmuxPane != nil { return "tmux" }
        switch program {
        case "iTerm.app": return "iTerm"
        case "Apple_Terminal": return "Terminal"
        case "ghostty": return "Ghostty"
        case "WezTerm": return "WezTerm"
        case "vscode": return "VS Code"
        case let other?: return other.replacingOccurrences(of: ".app", with: "")
        case nil: return "Terminal"
        }
    }

    /// Exact identity of the agent or terminal surface. The process wins because
    /// two agents may intentionally share a pane; pane/session/TTY values provide
    /// stable fallbacks for restored transcript rows that do not yet have a PID.
    var stableIdentity: String? {
        if let agentPID { return "pid:\(agentPID)" }
        if let tmuxPane { return "tmux:\(tmuxSocket ?? ""):\(tmuxPane)" }
        if let weztermPane { return "wezterm:\(weztermPane)" }
        if let kittyWindowID { return "kitty:\(kittyListenOn ?? ""):\(kittyWindowID)" }
        if let iTermSessionID { return "iterm:\(iTermSessionID)" }
        if let terminalSessionID { return "terminal:\(terminalSessionID)" }
        if let tty { return "tty:\(tty)" }
        return nil
    }
}

/// A concrete tab or pane presented when a terminal lookup has more than one
/// valid destination. It is remembered only on the live `AgentSession`.
struct TerminalDestination: Identifiable, Equatable, Sendable, Codable {
    enum Kind: String, Codable, Sendable { case ghostty }
    let kind: Kind
    let stableID: String
    let terminalName: String
    let title: String
    let workingDirectory: String?

    var id: String { "\(kind.rawValue):\(stableID)" }
}

/// One live CLI agent session.
struct AgentSession: Identifiable, Sendable {
    let id: String
    var provider: Provider
    /// Project directory basename, which is what a person recognises a session by.
    var project: String?
    /// The user's most recent instruction, shown as `You: …`.
    var lastPrompt: String?
    var activity: SessionActivity
    var terminal: TerminalRef?
    var selectedDestination: TerminalDestination? = nil
    var startedAt: Date
    var lastEventAt: Date

    /// The bold line in the panel. The first prompt makes a better title than the
    /// directory, so it wins once there is one.
    var title: String {
        if let lastPrompt, !lastPrompt.isEmpty { return AgentSession.condensed(lastPrompt) }
        if let project, !project.isEmpty { return project }
        return provider.title
    }

    /// Titles are one line in a narrow panel; a pasted paragraph has to become one.
    static func condensed(_ text: String, limit: Int = 48) -> String {
        let flattened = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard flattened.count > limit else { return flattened }
        return flattened.prefix(limit).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// `27m`, `1h`, `5h` — the elapsed column in the panel.
    var elapsed: String {
        let seconds = max(0, Int(Date.now.timeIntervalSince(startedAt)))
        if seconds >= 86_400 { return "\(seconds / 86_400)d" }
        if seconds >= 3_600 { return "\(seconds / 3_600)h" }
        if seconds >= 60 { return "\(seconds / 60)m" }
        return "\(seconds)s"
    }
}
