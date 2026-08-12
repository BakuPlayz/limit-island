import Foundation

/// Turns a tool call into the one-line description the panel shows.
///
/// Tool inputs are open-ended — an MCP server can define any shape it likes — so
/// every branch here is a best effort over a known name, and the fallback is the
/// tool's own name rather than a guess.
enum ToolSummary {
    /// Present tense, for a call that is running: "Writing middleware.ts".
    static func activity(tool: String, input: JSONValue?) -> String {
        switch tool {
        case "Edit", "MultiEdit", "NotebookEdit":
            file(input).map { "Editing \($0)" } ?? "Editing a file"
        case "Write":
            file(input).map { "Writing \($0)" } ?? "Writing a file"
        case "Read":
            file(input).map { "Reading \($0)" } ?? "Reading a file"
        case "Bash", "BashOutput":
            command(input).map { "Running \(condensed($0))" } ?? "Running a command"
        case "Grep", "Glob":
            input?.string("pattern").map { "Searching \(condensed($0))" } ?? "Searching"
        case "WebFetch", "WebSearch":
            "Searching the web"
        case "Task", "Agent":
            "Running a subagent"
        case "TodoWrite":
            "Updating its plan"
        case "ExitPlanMode":
            "Presenting a plan"
        default:
            tool
        }
    }

    /// What a permission card is being asked to approve: the tool and its target.
    static func target(tool: String, input: JSONValue?) -> String? {
        switch tool {
        case "Bash", "BashOutput": command(input)
        case "WebFetch": input?.string("url")
        default: file(input)
        }
    }

    static func file(_ input: JSONValue?) -> String? {
        guard let path = input?.string("file_path", "filePath", "path", "notebook_path") else { return nil }
        // Paths are absolute and long; the panel has room for the name.
        return (path as NSString).lastPathComponent
    }

    static func command(_ input: JSONValue?) -> String? {
        input?.string("command")
    }

    private static func condensed(_ text: String, limit: Int = 32) -> String {
        let flattened = text.replacingOccurrences(of: "\n", with: " ")
        guard flattened.count > limit else { return flattened }
        return flattened.prefix(limit).trimmingCharacters(in: .whitespaces) + "…"
    }
}
