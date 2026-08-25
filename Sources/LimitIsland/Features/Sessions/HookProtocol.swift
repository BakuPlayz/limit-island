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

    var sessionID: String? {
        payload.string("session_id", "sessionId", "thread_id", "threadId", "conversationId")
    }
    var toolName: String? {
        payload.string("tool_name", "toolName") ?? payload["toolCall"]?.string("name")
    }
    var toolInput: JSONValue? {
        payload["tool_input"] ?? payload["toolInput"]
            // Antigravity documents `args` and its binary carries that tag, but it
            // also carries `arguments` for the same thing; a rename here would cost
            // every card its detail without failing anywhere visible.
            ?? payload["toolCall"]?["args"] ?? payload["toolCall"]?["arguments"]
    }
    var workingDirectory: String? {
        // Antigravity opens a workspace rather than a directory, and sends every
        // root it was given. The first is the one the session belongs to.
        payload.string("cwd", "workspace_dir")
            ?? payload["workspacePaths"]?.arrayValue?.compactMap(\.stringValue).first
    }
    /// The model the CLI reported for this session, if it reports one at all.
    var model: String? { payload.string("modelName", "model") }
    var prompt: String? { payload.string("prompt", "user_prompt") }
    var message: String? { payload.string("message", "notification") }
    var notificationType: NotificationType {
        NotificationType(payload.string("notification_type", "notificationType"))
    }
    var transcriptPath: String? { payload.string("transcript_path", "transcriptPath") }

    /// Which permission mode the session is running in. Claude Code sends this on
    /// every `PreToolUse`, and it is the difference between a person who wants to be
    /// asked and one who has already said yes to everything.
    var permissionMode: PermissionMode {
        PermissionMode(rawPermissionMode)
    }

    /// The mode as actually reported, or nil when the event did not carry one.
    ///
    /// Not every event has the field. `permissionMode` folds that absence into
    /// `standard`, which is the safe reading for "should we ask?" — but it is the
    /// wrong reading for "what did the CLI do with the mode we set?", where a missing
    /// field says nothing at all and `standard` would be a false report of failure.
    var reportedPermissionMode: PermissionMode? {
        guard let raw = rawPermissionMode else { return nil }
        return PermissionMode(raw)
    }

    private var rawPermissionMode: String? {
        payload.string("permission_mode", "permissionMode", "approval_policy", "approvalPolicy")
    }

    var provider: Provider {
        switch cli {
        case "codex": .openAI
        case "gemini": .gemini
        default: .claude
        }
    }
}

enum NotificationType: Equatable, Sendable {
    case permissionPrompt, idlePrompt, elicitationDialog
    case passive
    case unknown

    init(_ raw: String?) {
        switch raw {
        case "permission_prompt": self = .permissionPrompt
        case "idle_prompt": self = .idlePrompt
        case "elicitation_dialog": self = .elicitationDialog
        case "auth_success", "elicitation_complete", "elicitation_response": self = .passive
        default: self = .unknown
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
    /// Claude's auto mode. The CLI ranks it above accept-edits and below bypass, and
    /// reaches it through a gate of its own that can refuse. Kept distinct from
    /// `bypass` for exactly that reason: a switch into it has to be checked, and a
    /// mode folded into another cannot be.
    case auto
    /// Nothing asks.
    case bypass
    /// Planning; no edits happen, and the decision that matters is the plan itself.
    case plan

    init(_ raw: String?) {
        // Unknown values fall back to `standard`, which asks. A mode we do not
        // recognise should never be read as blanket permission.
        switch raw {
        case "acceptEdits": self = .acceptEdits
        case "auto": self = .auto
        case "bypassPermissions", "dangerously-skip-permissions", "never", "full-auto": self = .bypass
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
        case .acceptEdits, .auto:
            // Claude's auto and accept-edits modes are an explicit request for an
            // uninterrupted run. Even tools outside the edit family stay in the
            // terminal's own policy flow rather than gaining notch prompts.
            return false
        case .plan:
            // Nothing is being changed yet, so the only thing worth surfacing is
            // the plan waiting for approval.
            return tool == "ExitPlanMode"
        }
    }

    static let editTools: Set<String> = ["Edit", "MultiEdit", "Write", "NotebookEdit"]

    /// What "auto approve" asks a Claude session to become.
    ///
    /// Accept-edits rather than Claude's own `auto`: a mode set through a hook is
    /// applied without the CLI's auto-mode gate ever running, and a session left in
    /// `auto` with that gate shut is put back into `default` — which asks about
    /// *more* than before the plan was approved. Accept-edits has no gate and is
    /// applied unconditionally, which is what a button promising "without asking
    /// again" needs.
    static let autoApprove = "acceptEdits"

    var isAutomatic: Bool { self == .acceptEdits || self == .auto || self == .bypass }
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
    var updatedInput: JSONValue? = nil
    var updatedPermissionMode: String? = nil

    enum Decision: String, Sendable {
        case allow
        case deny
    }

    static let noOpinion = HookReply(decision: nil)

    /// Claude Code's `PreToolUse` output shape, or the CLI's own where it differs.
    func serialised(for event: HookEvent? = nil, reason: String?) -> String {
        guard let decision else { return "{}" }
        // Antigravity answers with a flat decision object of its own, and reads
        // `ask` as "put your own prompt up" — which is exactly what no opinion
        // means to it, so only a real answer is ever sent.
        if event?.provider == .gemini {
            var root: [String: Any] = ["decision": decision.rawValue]
            if let reason { root["reason"] = reason }
            guard let data = try? JSONSerialization.data(withJSONObject: root),
                  let text = String(data: data, encoding: .utf8) else { return "{}" }
            return text
        }
        if event?.event == "PermissionRequest" {
            var decisionObject: [String: Any] = ["behavior": decision.rawValue]
            // `message` belongs to the deny arm of the CLI's schema; the allow arm
            // takes only `updatedInput` and `updatedPermissions`. It is dropped
            // rather than rejected, but sending it claims a shape that does not exist.
            if let reason, decision == .deny { decisionObject["message"] = reason }
            if let updatedPermissionMode {
                decisionObject["updatedPermissions"] = [["type": "setMode", "mode": updatedPermissionMode, "destination": "session"]]
            }
            let root: [String: Any] = ["hookSpecificOutput": [
                "hookEventName": "PermissionRequest", "decision": decisionObject
            ]]
            guard let data = try? JSONSerialization.data(withJSONObject: root),
                  let text = String(data: data, encoding: .utf8) else { return "{}" }
            return text
        }
        var specific: [String: Any] = [
            "hookEventName": "PreToolUse",
            "permissionDecision": decision.rawValue
        ]
        if let reason { specific["permissionDecisionReason"] = reason }
        if let updatedInput,
           let data = try? JSONEncoder().encode(updatedInput),
           let object = try? JSONSerialization.jsonObject(with: data) {
            specific["updatedInput"] = object
        }
        let root: [String: Any] = ["hookSpecificOutput": specific]
        guard let data = try? JSONSerialization.data(withJSONObject: root),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }
}
