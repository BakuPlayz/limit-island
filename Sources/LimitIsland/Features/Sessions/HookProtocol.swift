import Foundation

/// The wire format between `limitisland-hook` and the app.
///
/// One newline-terminated JSON object each way over a Unix stream socket. The
/// helper builds its side with `JSONSerialization` rather than sharing this file,
/// so the two targets stay independent — this type is the specification, and
/// `HookProtocolTests` is what keeps the two honest.
struct HookEvent: Decodable, Sendable {
    /// `PreToolUse`, `UserPromptSubmit`, `Notification`, `Stop`, … — whatever the
    /// CLI called the hook. Unknown names are recorded and otherwise ignored.
    let event: String
    /// Which CLI sent it: `claude`, `codex`, `gemini`.
    let cli: String
    /// The CLI's own hook payload, verbatim.
    let payload: JSONValue
    /// Terminal-identifying variables the CLI inherited.
    let env: [String: String]
    /// The helper's process and its ancestors, nearest first.
    let pids: [Int32]
    /// Controlling terminal device, empty when there is none.
    let tty: String
    let sentAt: TimeInterval

    var sessionID: String? { payload.string("session_id", "sessionId", "thread_id", "threadId") }
    var toolName: String? { payload.string("tool_name", "toolName") }
    var toolInput: JSONValue? { payload["tool_input"] ?? payload["toolInput"] }
    var workingDirectory: String? { payload.string("cwd", "workspace_dir") }
    var prompt: String? { payload.string("prompt", "user_prompt") }
    var message: String? { payload.string("message", "notification") }
    var transcriptPath: String? { payload.string("transcript_path", "transcriptPath") }

    /// Which permission mode the session is running in. Claude Code sends this on
    /// every `PreToolUse`, and it is the difference between a person who wants to be
    /// asked and one who has already said yes to everything.
    var permissionMode: PermissionMode {
        PermissionMode(payload.string("permission_mode", "permissionMode"))
    }

    var provider: Provider {
        switch cli {
        case "codex": .openAI
        case "gemini": .gemini
        default: .claude
        }
    }
}

/// The permission mode a CLI session is running in.
///
/// This exists so Limit Island does not re-introduce prompts the person has
/// deliberately turned off. Someone running in auto-accept has already answered the
/// question the notch would be asking, and putting a card in front of them for every
/// edit would make the app worse than not having it.
enum PermissionMode: Equatable, Sendable {
    /// Ask, per the user's rules. The only mode the notch decides anything in.
    case standard
    /// Edits are accepted automatically; other tools still ask.
    case acceptEdits
    /// Nothing asks.
    case bypass
    /// Planning; no edits happen, and the decision that matters is the plan itself.
    case plan

    init(_ raw: String?) {
        // Unknown values fall back to `standard`, which asks. A mode we do not
        // recognise should never be read as blanket permission.
        switch raw {
        case "acceptEdits": self = .acceptEdits
        case "bypassPermissions", "dangerously-skip-permissions": self = .bypass
        case "plan": self = .plan
        default: self = .standard
        }
    }

    /// Whether a decision about `tool` is the person's to make in this mode.
    func asksAbout(_ tool: String) -> Bool {
        switch self {
        case .standard:
            return true
        case .bypass:
            return false
        case .acceptEdits:
            // `acceptEdits` covers edits only; a Bash command still stops.
            return !PermissionMode.editTools.contains(tool)
        case .plan:
            // Nothing is being changed yet, so the only thing worth surfacing is
            // the plan waiting for approval.
            return tool == "ExitPlanMode"
        }
    }

    static let editTools: Set<String> = ["Edit", "MultiEdit", "Write", "NotebookEdit"]
}

/// What the app sends back. Only blocking events read it.
///
/// The field is the literal JSON the CLI expects on the hook's stdout, so this type
/// never has to track the CLI's evolving hook-output schema — only the two decision
/// strings it currently emits.
struct HookReply: Sendable {
    /// `nil` means "no opinion": the helper prints nothing and the CLI's own
    /// permission flow runs exactly as it would without us.
    var decision: Decision?

    enum Decision: String, Sendable {
        case allow
        case deny
    }

    static let noOpinion = HookReply(decision: nil)

    /// Claude Code's `PreToolUse` output shape.
    func serialised(reason: String?) -> String {
        guard let decision else { return "{}" }
        var specific: [String: Any] = [
            "hookEventName": "PreToolUse",
            "permissionDecision": decision.rawValue
        ]
        if let reason { specific["permissionDecisionReason"] = reason }
        let root: [String: Any] = ["hookSpecificOutput": specific]
        guard let data = try? JSONSerialization.data(withJSONObject: root),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }
}
