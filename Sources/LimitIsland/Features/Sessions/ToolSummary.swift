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
        // Codex's is `request_user_input`, which is the one name here a person would
        // never have typed and should never have to read.
        case "AskUserQuestion", "request_user_input":
            "Asking a question"
        // Antigravity names its tools after its own step types, lowercased.
        case "edit_file", "propose_code", "file_change", "replace_file_content":
            file(input).map { "Editing \($0)" } ?? "Editing a file"
        case "write_to_file", "write_blob", "create_file":
            file(input).map { "Writing \($0)" } ?? "Writing a file"
        case "view_file", "view_file_outline", "view_code_item", "read_notebook":
            file(input).map { "Reading \($0)" } ?? "Reading a file"
        case "run_command", "shell_exec", "send_command_input":
            command(input).map { "Running \(condensed($0))" } ?? "Running a command"
        case "grep_search", "code_search", "find", "list_directory":
            input?.string("Query", "SearchTerm", "query", "pattern")
                .map { "Searching \(condensed($0))" } ?? "Searching"
        case "search_web", "read_url_content", "open_browser_url":
            "Searching the web"
        case "invoke_subagent":
            "Running a subagent"
        default:
            tool
        }
    }

    /// What a permission card is being asked to approve: the tool and its target.
    static func target(tool: String, input: JSONValue?) -> String? {
        switch tool {
        case "Bash", "BashOutput", "run_command", "shell_exec": command(input)
        case "WebFetch": input?.string("url")
        case "read_url_content", "open_browser_url": input?.string("Url", "url")
        default: file(input)
        }
    }

    static func file(_ input: JSONValue?) -> String? {
        guard let path = input?.string(
            "file_path", "filePath", "path", "notebook_path",
            // Antigravity's own arguments are TitleCase.
            "TargetFile", "AbsolutePath", "NotebookPath"
        ) else { return nil }
        // Paths are absolute and long; the panel has room for the name.
        return (path as NSString).lastPathComponent
    }

    static func command(_ input: JSONValue?) -> String? {
        input?.string("command", "CommandLine")
    }

    private static func condensed(_ text: String, limit: Int = 32) -> String {
        let flattened = text.replacingOccurrences(of: "\n", with: " ")
        guard flattened.count > limit else { return flattened }
        return flattened.prefix(limit).trimmingCharacters(in: .whitespaces) + "…"
    }
}
