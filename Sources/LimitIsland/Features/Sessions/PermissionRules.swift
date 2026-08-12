import Foundation

/// The user's own Claude Code permission rules, evaluated locally.
///
/// This exists to stop the notch making things *worse*. A `PreToolUse` hook runs
/// before Claude Code decides whether it needs to ask, so a card shown for every
/// matched tool would re-prompt for calls the user had already allowlisted — the
/// notch would add friction rather than remove it.
///
/// So: rules the user has already written are applied here first, and a call they
/// cover passes straight through with no card and no decision from us. Only a call
/// that Claude Code would genuinely have stopped on reaches the panel.
///
/// It is a *subset* of Claude Code's matching, on purpose. When a rule cannot be
/// evaluated confidently the answer is `.undecided`, which shows the card — an
/// extra prompt is a nuisance, whereas silently allowing something the user never
/// approved is a broken promise.
struct PermissionRules: Sendable {
    enum Outcome: Equatable {
        case allowed
        case denied
        case undecided
    }

    var allow: [Rule] = []
    var deny: [Rule] = []
    var ask: [Rule] = []

    struct Rule: Equatable, Sendable {
        let tool: String
        /// The text inside the parentheses, if any: `Bash(git status:*)` → `git status:*`.
        let specifier: String?

        init?(_ raw: String) {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }
            guard let open = trimmed.firstIndex(of: "("), trimmed.hasSuffix(")") else {
                tool = trimmed
                specifier = nil
                return
            }
            tool = String(trimmed[trimmed.startIndex..<open]).trimmingCharacters(in: .whitespaces)
            let inner = trimmed[trimmed.index(after: open)..<trimmed.index(before: trimmed.endIndex)]
            specifier = inner.isEmpty ? nil : String(inner)
        }
    }

    // MARK: - Evaluation

    func outcome(tool: String, input: JSONValue?) -> Outcome {
        // Deny wins, then an explicit ask, then allow — the same precedence Claude
        // Code applies, so a rule written to force a prompt still forces one.
        if deny.contains(where: { $0.matches(tool: tool, input: input) }) { return .denied }
        if ask.contains(where: { $0.matches(tool: tool, input: input) }) { return .undecided }
        if allow.contains(where: { $0.matches(tool: tool, input: input) }) { return .allowed }
        return .undecided
    }

    // MARK: - Loading

    /// User settings, then project settings, then local overrides — later files add
    /// to the rule set rather than replacing it, which matches how Claude Code
    /// layers them for the purpose we care about (is this call already covered?).
    /// `nonisolated` so the caller can get this off the main actor. It reads up to
    /// three files, and it runs on every intercepted tool call while an agent waits
    /// on the answer — main-actor file I/O in that position stalls the whole UI.
    nonisolated static func load(projectDirectory: String?) -> PermissionRules {
        var sources = [
            URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/settings.json")
        ]
        if let projectDirectory {
            let project = URL(fileURLWithPath: projectDirectory)
            sources.append(project.appendingPathComponent(".claude/settings.json"))
            sources.append(project.appendingPathComponent(".claude/settings.local.json"))
        }

        var rules = PermissionRules()
        for url in sources {
            guard let data = try? Data(contentsOf: url),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let permissions = root["permissions"] as? [String: Any] else { continue }
            rules.allow += parse(permissions["allow"])
            rules.deny += parse(permissions["deny"])
            rules.ask += parse(permissions["ask"])
        }
        return rules
    }

    private static func parse(_ value: Any?) -> [Rule] {
        guard let entries = value as? [String] else { return [] }
        return entries.compactMap(Rule.init)
    }
}

extension PermissionRules.Rule {
    func matches(tool candidateTool: String, input: JSONValue?) -> Bool {
        guard tool == candidateTool else { return false }
        // A bare tool name covers every call to it.
        guard let specifier else { return true }

        switch candidateTool {
        case "Bash", "BashOutput":
            guard let command = ToolSummary.command(input) else { return false }
            return Self.matchesCommand(command, specifier: specifier)
        case "Read", "Edit", "MultiEdit", "Write", "NotebookEdit":
            guard let path = input?.string("file_path", "filePath", "path", "notebook_path") else { return false }
            return Self.matchesPath(path, pattern: specifier)
        case "WebFetch":
            guard let url = input?.string("url") else { return false }
            // `WebFetch(domain:example.com)`
            guard let domain = specifier.split(separator: ":", maxSplits: 1).last, specifier.hasPrefix("domain:") else { return false }
            return URL(string: url)?.host?.hasSuffix(String(domain)) == true
        default:
            // An unfamiliar tool's specifier grammar is unknown, so claim nothing.
            return false
        }
    }

    /// `git status:*` means "commands starting with `git status`"; a specifier with
    /// no `:*` is an exact command.
    private static func matchesCommand(_ command: String, specifier: String) -> Bool {
        let normalised = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard specifier.hasSuffix(":*") else { return normalised == specifier }
        let prefix = String(specifier.dropLast(2))
        guard normalised.hasPrefix(prefix) else { return false }
        // Only allow a prefix rule to cover a single command. `git status && rm -rf`
        // starts with `git status` but is emphatically not what the rule permitted.
        return !normalised.contains("&&")
            && !normalised.contains("||")
            && !normalised.contains(";")
            && !normalised.contains("|")
            && !normalised.contains("`")
            && !normalised.contains("$(")
    }

    private static func matchesPath(_ path: String, pattern: String) -> Bool {
        // `fnmatch` is what the shell would do, and handles `//**` and `*` alike.
        pattern.withCString { patternPointer in
            path.withCString { pathPointer in
                fnmatch(patternPointer, pathPointer, 0) == 0
            }
        }
    }
}
