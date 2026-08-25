import Foundation

/// Reads Codex's session rollout files.
///
/// Codex has no hook that can be asked a question, and its only hook — `notify` —
/// fires once a turn ends. Everything between prompts would be invisible if that
/// were the whole story. But Codex writes a full transcript as it goes, one JSON
/// object per line, to `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`, and that
/// carries the prompt, the tool calls and the turn boundaries as they happen.
///
/// This is an undocumented internal format, so every field is optional and an
/// unrecognised record is skipped rather than treated as an error. The parser is
/// separated from the file watching so it can be tested against recorded lines
/// without touching the filesystem.
enum CodexRolloutParser {
    enum TranscriptSource: Equatable {
        case user
        case subagent
        case unknown
    }

    /// One meaningful thing that happened in a Codex session.
    enum Record: Equatable {
        /// The session opened: its identifier and working directory.
        case started(sessionID: String, workingDirectory: String?, source: TranscriptSource)
        /// The person asked for something.
        case prompt(String)
        /// A turn began.
        case turnStarted
        /// A turn finished.
        case turnCompleted
        /// The agent is doing something; the string is the panel's activity line.
        case activity(String)
        /// Codex has paused in its terminal and is waiting for the person.
        case question(AgentQuestion)
        /// The terminal accepted the response to a preceding function call.
        case functionAnswered
        /// Codex's own approval policy for the session.
        case approvalPolicy(PermissionMode)
    }

    /// The model named by one line, if it names one.
    ///
    /// Read separately from `record(from:)` rather than as another `Record` case:
    /// the lines that carry a model carry the approval policy too, and a line can
    /// only produce one record. Both matter, so neither may displace the other.
    static func model(from line: Data) -> String? {
        guard let root = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let payload = root["payload"] as? [String: Any] else { return nil }
        switch root["type"] as? String {
        case "turn_context":
            return payload["model"] as? String
        case "event_msg":
            guard payload["type"] as? String == "thread_settings_applied",
                  let settings = payload["thread_settings"] as? [String: Any] else { return nil }
            return settings["model"] as? String
        default:
            return nil
        }
    }

    /// Decodes one line. Returns nil for the many records that say nothing the panel
    /// shows — reasoning, token counts, world state and the rest.
    static func record(from line: Data) -> Record? {
        guard let root = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return nil }
        let payload = root["payload"] as? [String: Any] ?? [:]

        switch root["type"] as? String {
        case "session_meta":
            guard let id = payload["session_id"] as? String ?? payload["id"] as? String else { return nil }
            return .started(
                sessionID: id,
                workingDirectory: payload["cwd"] as? String,
                source: transcriptSource(payload["source"])
            )

        case "event_msg":
            return eventRecord(payload)

        case "response_item":
            return responseRecord(payload)

        case "turn_context":
            // Current Codex/Sol rollouts repeat the effective policy here. This is
            // often the first reliable auto-mode signal for a resumed session.
            if let raw = payload["approval_policy"] as? String ?? payload["approvalPolicy"] as? String {
                return .approvalPolicy(PermissionMode(codexApprovalPolicy: raw))
            }
            return nil

        default:
            return nil
        }
    }

    /// Root CLI rollouts are user-facing. Codex has used both strings and nested
    /// objects for internal agent sources, so classify recursively and default old
    /// source-less files to unknown rather than accidentally calling them internal.
    private static func transcriptSource(_ value: Any?) -> TranscriptSource {
        guard let value else { return .unknown }
        let description: String
        if let string = value as? String {
            description = string
        } else if JSONSerialization.isValidJSONObject(value),
                  let data = try? JSONSerialization.data(withJSONObject: value),
                  let string = String(data: data, encoding: .utf8) {
            description = string
        } else {
            description = String(describing: value)
        }
        let source = description.lowercased()
        if ["subagent", "guardian", "reviewer", "compact"].contains(where: source.contains) {
            return .subagent
        }
        if ["cli", "user", "root"].contains(where: source.contains) { return .user }
        return .unknown
    }

    private static func eventRecord(_ payload: [String: Any]) -> Record? {
        switch payload["type"] as? String {
        case "user_message":
            guard let message = payload["message"] as? String, !message.isEmpty else { return nil }
            return .prompt(message)

        case "task_started":
            return .turnStarted

        case "task_complete":
            return .turnCompleted

        case "patch_apply_end":
            // stdout names the files: "Success. Updated the following files:\nA Package.swift".
            let files = editedFiles(in: payload["stdout"] as? String ?? "")
            switch files.count {
            case 0: return .activity("Editing files")
            case 1: return .activity("Editing \(files[0])")
            default: return .activity("Editing \(files.count) files")
            }

        case "web_search_end":
            return .activity("Searching the web")

        case "agent_message":
            // The agent talking is the end of its thinking, not an activity of its
            // own; the turn's completion is what the panel reports.
            return nil

        case "thread_settings_applied":
            guard let settings = payload["thread_settings"] as? [String: Any] else { return nil }
            return .approvalPolicy(PermissionMode(codexApprovalPolicy: settings["approval_policy"] as? String))

        default:
            return nil
        }
    }

    private static func responseRecord(_ payload: [String: Any]) -> Record? {
        switch payload["type"] as? String {
        case "custom_tool_call":
            // Codex's shell tool arrives as `exec` with a JavaScript-ish `input`
            // wrapping the real command, e.g.
            // `const r = await tools.exec_command({"cmd":["bash","-lc","npm test"]})`.
            guard payload["name"] as? String == "exec" else { return nil }
            guard let command = command(in: payload["input"] as? String ?? "") else {
                return .activity("Running a command")
            }
            return .activity("Running \(condensed(command))")

        case "function_call":
            guard let name = payload["name"] as? String else { return nil }
            if name == "request_user_input" {
                guard let question = question(in: payload["arguments"] as? String) else { return nil }
                return .question(question)
            }
            return nil

        case "function_call_output":
            // `request_user_input` returns an answers object. Other function calls
            // also produce this record type and must not dismiss an active card.
            guard let output = payload["output"] as? String,
                  output.contains("\"answers\"") else { return nil }
            return .functionAnswered

        default:
            return nil
        }
    }

    /// Extracts the first visible question from Codex's JSON-encoded arguments.
    /// Keeping the text means the island says what needs attention, while clicking
    /// the row returns to Codex's native option picker to answer it.
    static func question(in arguments: String?) -> AgentQuestion? {
        guard let arguments,
              let data = arguments.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data) else { return nil }
        return AgentQuestion.parse(value)
    }

    // MARK: - Digging values out of free text

    /// Pulls the command out of the `exec` wrapper. The shape is not documented, so
    /// this looks for the `cmd` array and falls back to saying nothing rather than
    /// guessing wrongly.
    static func command(in input: String) -> String? {
        guard let range = input.range(of: "\"cmd\"") else { return nil }
        let rest = input[range.upperBound...]
        guard let open = rest.firstIndex(of: "["), let close = rest[open...].firstIndex(of: "]") else { return nil }
        let array = String(rest[rest.index(after: open)..<close])
        // Take the last string in the array: `["bash","-lc","npm test"]` is the
        // common shape and the command itself is the interesting part.
        let parts = array
            .components(separatedBy: "\",")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"")) }
            .filter { !$0.isEmpty }
        guard let last = parts.last else { return nil }
        return last
            .replacingOccurrences(of: "\\n", with: " ")
            .replacingOccurrences(of: "\\\"", with: "\"")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `A Package.swift` / `M Sources/x.swift` lines from a patch summary.
    static func editedFiles(in stdout: String) -> [String] {
        stdout
            .components(separatedBy: "\n")
            .compactMap { line in
                let parts = line.split(separator: " ", maxSplits: 1)
                guard parts.count == 2, parts[0].count == 1, "AMD".contains(parts[0]) else { return nil }
                return (String(parts[1]) as NSString).lastPathComponent
            }
    }

    private static func condensed(_ text: String, limit: Int = 32) -> String {
        let flattened = text.replacingOccurrences(of: "\n", with: " ")
        guard flattened.count > limit else { return flattened }
        return flattened.prefix(limit).trimmingCharacters(in: .whitespaces) + "…"
    }
}

extension PermissionMode {
    /// Codex names its modes differently from Claude Code, but they mean the same
    /// things: `never` asks for nothing, `on-request` asks when it needs to.
    init(codexApprovalPolicy raw: String?) {
        switch raw {
        case "never": self = .bypass
        case "on-failure", "on-request", "untrusted": self = .standard
        default: self = .standard
        }
    }
}
