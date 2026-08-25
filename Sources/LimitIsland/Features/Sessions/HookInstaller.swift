import Foundation

/// Writes Limit Island's hooks into the CLIs' own configuration, and takes them
/// back out again.
///
/// This edits a file the user has asked Limit Island to manage, so it holds itself
/// to three rules:
///
/// * **Never lose a key.** The file is parsed, amended and re-serialised — every
///   setting that was there before is still there after, including ones this app
///   has never heard of.
/// * **Back up first, write atomically.** A timestamped copy goes into our support
///   directory before anything is written, and the write is temp-file-plus-rename
///   so a crash mid-write cannot leave a truncated settings file behind.
/// * **Remove only our own.** Uninstall matches on the helper's path, so hooks the
///   user (or another tool) added survive.
enum HookInstaller {
    private enum DefaultsKey {
        static let automaticNotice = "limit-island.automatic-hook-notice"
    }

    private struct ReplacedCodexNotify: Codable {
        let line: String
    }

    /// Where the helper lives inside the app bundle. During development the app is
    /// run from `.build`, so fall back to the executable's own directory.
    static var helperURL: URL {
        let executable = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        let bundled = executable
            .deletingLastPathComponent()          // …/Contents/MacOS
            .deletingLastPathComponent()          // …/Contents
            .appendingPathComponent("Helpers/limitisland-hook")
        if FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled }
        return executable.deletingLastPathComponent().appendingPathComponent("limitisland-hook")
    }

    static var claudeSettingsURL: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/settings.json")
    }

    static var codexConfigURL: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/config.toml")
    }

    static var codexHooksURL: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/hooks.json")
    }

    /// Antigravity's machine-local customization root. The CLI, the IDE and the
    /// desktop app all read it, so a hook installed here covers every Gemini agent
    /// on this machine.
    static var geminiHooksURL: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".gemini/config/hooks.json")
    }

    /// The one top-level key this app owns in that file. Antigravity merges hook
    /// bundles by name, so ours sits beside anyone else's and uninstall is the
    /// removal of exactly this key.
    static let geminiHookName = "limit-island"

    private static var replacedCodexNotifyURL: URL {
        HookServer.supportDirectory.appendingPathComponent("replaced-codex-notify.json")
    }

    static var automaticNotice: String? {
        UserDefaults.standard.string(forKey: DefaultsKey.automaticNotice)
    }

    static func commandIsAvailable(_ command: String) -> Bool {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin"
        return path.split(separator: ":").contains {
            FileManager.default.isExecutableFile(atPath: String($0) + "/" + command)
        }
    }

    static func installClaudeAutomaticallyIfAvailable() {
        guard commandIsAvailable("claude") else { return }
        let before = state()
        guard before != .installed else { return }
        do {
            try install()
            // Claude Code reads settings.json when a session starts, so an install or a
            // repair reaches only the sessions started after it. Saying so is the
            // difference between "the notch is broken" and "restart that terminal".
            setAutomaticNotice(
                before == .absent
                    ? "Claude hooks installed automatically. Sessions already running keep their old hooks until they restart."
                    : "Claude hooks updated automatically. Restart any running session for it to be answerable from the island."
            )
        } catch {
            setAutomaticNotice("Claude hooks need attention: \(error.localizedDescription)")
            Log.hooks.error("automatic Claude hook install failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func installCodexAutomatically() {
        guard codexState() != .installed else { return }
        do {
            try installCodex()
            setAutomaticNotice("Codex terminal hook installed automatically for future sessions.")
        } catch {
            setAutomaticNotice("Codex terminal hook needs attention: \(error.localizedDescription)")
            Log.hooks.error("automatic Codex notify install failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    enum State: Equatable {
        case installed
        case absent
        /// Ours are there but point at a different build of the helper — which is
        /// what a moved or renamed app bundle looks like, and would silently stop
        /// reporting until it is reinstalled.
        case stale
    }

    /// Every event we ask for. `PreToolUse` is the only blocking one; the rest are
    /// reports and cost the CLI a couple of milliseconds each.
    static let events = [
        "SessionStart",
        "UserPromptSubmit",
        "PreToolUse",
        "PermissionRequest",
        "PostToolUse",
        "Notification",
        "Stop",
        "SessionEnd"
    ]

    /// Generous, because `PreToolUse` may be waiting on a person. It is deliberately
    /// longer than `SessionStore.decisionTimeout`, so the app gives up first and
    /// hands the prompt back rather than the CLI killing the hook mid-question.
    private static let blockingTimeoutSeconds = 540
    private static let reportingTimeoutSeconds = 5

    // MARK: - Reading

    static func state() -> State {
        state(of: readSettings(claudeSettingsURL))
    }

    /// Split from `state()` so the judgement can be tested without a settings file.
    static func state(of settings: [String: Any]?) -> State {
        guard let settings, let hooks = settings["hooks"] as? [String: Any] else { return .absent }
        let commands = ourCommands(in: hooks)
        guard !commands.isEmpty else { return .absent }
        let expected = helperURL.path
        guard commands.allSatisfy({ $0.hasPrefix(expected) }) else { return .stale }
        // A settings file written before an event joined `events` is as broken as one
        // pointing at a moved bundle: the app looks installed and silently never hears
        // about the thing that event carries. `PermissionRequest` was added this way,
        // and its absence is why plan approvals never reached the notch.
        return eventsMissing(from: hooks).isEmpty ? .installed : .stale
    }

    static func eventsMissing(from hooks: [String: Any]) -> Set<String> {
        var installed: Set<String> = []
        for (event, value) in hooks {
            guard let matchers = value as? [[String: Any]] else { continue }
            let ours = matchers
                .compactMap { $0["hooks"] as? [[String: Any]] }
                .flatMap { $0 }
                .contains { isOurs($0["command"] as? String) }
            if ours { installed.insert(event) }
        }
        return Set(events).subtracting(installed)
    }

    // MARK: - Writing

    static func install() throws {
        var settings = readSettings(claudeSettingsURL) ?? [:]
        var hooks = settings["hooks"] as? [String: Any] ?? [:]

        for event in events {
            var matchers = (hooks[event] as? [[String: Any]]) ?? []
            // Drop any previous entry of ours so reinstalling after a move updates
            // the path instead of stacking a second copy.
            matchers = matchers.compactMap { pruneOurHooks(from: $0) }
            matchers.append(matcherEntry(for: event))
            hooks[event] = matchers
        }

        settings["hooks"] = hooks
        try write(settings, to: claudeSettingsURL)
        Log.hooks.info("installed hooks into \(claudeSettingsURL.path, privacy: .public)")
    }

    static func uninstall() throws {
        guard var settings = readSettings(claudeSettingsURL),
              var hooks = settings["hooks"] as? [String: Any] else { return }

        for (event, value) in hooks {
            guard let matchers = value as? [[String: Any]] else { continue }
            let remaining = matchers.compactMap { pruneOurHooks(from: $0) }
            // An event left with no matchers should disappear rather than persist
            // as an empty array we put there.
            hooks[event] = remaining.isEmpty ? nil : remaining
        }

        settings["hooks"] = hooks.isEmpty ? nil : hooks
        try write(settings, to: claudeSettingsURL)
        Log.hooks.info("removed hooks from \(claudeSettingsURL.path, privacy: .public)")
    }

    // MARK: - Codex

    /// Codex's config is TOML, and the user's copy is mostly `[projects."…"]`
    /// tables. There is no TOML library here and adding one to write a single
    /// key would be absurd, so the edit is line-based and deliberately narrow:
    /// replace or append exactly one top-level `notify` line and copy every other
    /// byte through untouched.
    ///
    /// Line-based editing of a structured format is normally a poor idea. It is
    /// defensible here only because the change is one key with a scalar value, and
    /// because the alternative — reserialising a document we only partly understand
    /// — risks losing settings this app has no business touching.
    static func codexNotifyLine() -> String {
        "notify = [\"\(helperURL.path)\", \"notify\", \"codex\"]"
    }

    /// The Codex hook events this app installs.
    ///
    /// `PermissionRequest` carries approvals. `PreToolUse` carries questions:
    /// `request_user_input` is a normal tool call as far as hooks are concerned, so
    /// blocking it is the only way to answer Codex with data rather than by firing
    /// arrow keys at its picker.
    ///
    /// Neither entry takes a `matcher`. Codex honours a matcher-less entry — that is
    /// how the approval hook has always been installed — and scoping `PreToolUse` to
    /// one tool name would be an unverified guess at matcher syntax that fails
    /// closed. The narrowing happens in the helper instead, which answers anything
    /// that is not a question without ever opening the socket.
    static let codexEvents = ["PermissionRequest", "PreToolUse"]

    static func codexState() -> State {
        guard let contents = try? String(contentsOf: codexConfigURL, encoding: .utf8) else { return .absent }
        guard let line = contents
            .components(separatedBy: .newlines)
            .first(where: { isOurNotifyLine($0) }) else { return .absent }
        guard line.contains(helperURL.path) else { return .stale }
        guard let settings = readSettings(codexHooksURL),
              let hooks = settings["hooks"] as? [String: Any],
              !ourCommands(in: hooks).isEmpty else { return .absent }
        // An install predating the question hook has the approval hook and nothing
        // else. It works, so it is not `absent`, but it cannot answer a question —
        // `stale` is what puts the reinstall prompt in front of the person.
        guard codexEvents.allSatisfy({ !ourCommands(in: hooks, event: $0).isEmpty }) else { return .stale }
        return .installed
    }

    static func installCodex() throws {
        let existing = (try? String(contentsOf: codexConfigURL, encoding: .utf8)) ?? ""
        try backUp(codexConfigURL)

        var lines = existing.components(separatedBy: "\n")
        let firstTable = lines.firstIndex { $0.trimmingCharacters(in: .whitespaces).hasPrefix("[") } ?? lines.endIndex
        if let index = lines[..<firstTable].firstIndex(where: isTopLevelNotifyLine) {
            if !isOurNotifyLine(lines[index]) {
                try rememberReplacedCodexNotify(lines[index])
            }
            lines[index] = codexNotifyLine()
        } else if firstTable < lines.endIndex {
            // A top-level key has to go *above* the first table header, or TOML
            // reads it as belonging to that table. Getting this wrong would put
            // `notify` inside one of the user's `[projects."…"]` entries.
            lines.insert(codexNotifyLine(), at: firstTable)
            lines.insert("", at: firstTable + 1)
        } else {
            if !lines.isEmpty, lines.last?.isEmpty == false { lines.append("") }
            lines.append(codexNotifyLine())
        }

        try write(lines.joined(separator: "\n"), to: codexConfigURL)
        var settings = readSettings(codexHooksURL) ?? [:]
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        for event in codexEvents {
            var matchers = hooks[event] as? [[String: Any]] ?? []
            matchers = matchers.compactMap { pruneOurHooks(from: $0) }
            matchers.append(["hooks": [[
                "type": "command",
                "command": "\"\(helperURL.path)\" \(event) codex",
                "timeout": blockingTimeoutSeconds
            ]]])
            hooks[event] = matchers
        }
        settings["hooks"] = hooks
        try write(settings, to: codexHooksURL)
        Log.hooks.info("installed codex notify into \(codexConfigURL.path, privacy: .public)")
    }

    static func uninstallCodex() throws {
        guard let existing = try? String(contentsOf: codexConfigURL, encoding: .utf8) else { return }
        try backUp(codexConfigURL)
        var lines = existing.components(separatedBy: "\n")
        if let previous = replacedCodexNotify(), let index = lines.firstIndex(where: isOurNotifyLine) {
            lines[index] = previous.line
            try? FileManager.default.removeItem(at: replacedCodexNotifyURL)
        } else {
            lines.removeAll(where: isOurNotifyLine)
        }
        try write(lines.joined(separator: "\n"), to: codexConfigURL)
        if var settings = readSettings(codexHooksURL), var hooks = settings["hooks"] as? [String: Any] {
            for (event, value) in hooks {
                guard let matchers = value as? [[String: Any]] else { continue }
                let remaining = matchers.compactMap { pruneOurHooks(from: $0) }
                hooks[event] = remaining.isEmpty ? nil : remaining
            }
            settings["hooks"] = hooks.isEmpty ? nil : hooks
            try write(settings, to: codexHooksURL)
        }
        Log.hooks.info("removed codex notify from \(codexConfigURL.path, privacy: .public)")
    }

    // MARK: - Gemini (Antigravity)

    /// The events Antigravity offers. There is no `SessionStart` or `SessionEnd`:
    /// `PreInvocation` is the first thing a turn does, and a finished session is
    /// noticed by its process going away.
    static let geminiEvents = ["PreToolUse", "PostToolUse", "PreInvocation", "PostInvocation", "Stop"]

    /// Only `PreToolUse` can be answered; the rest report.
    private static let geminiBlockingEvents: Set<String> = ["PreToolUse"]

    /// Tool-scoped events take a `matcher`/`hooks` wrapper; the others are a flat
    /// list of handlers. Sending the wrong one is accepted and silently ignored.
    private static let geminiGroupedEvents: Set<String> = ["PreToolUse", "PostToolUse"]

    static func geminiState() -> State {
        geminiState(of: readSettings(geminiHooksURL))
    }

    /// Split from `geminiState()` so the judgement can be tested without a file.
    static func geminiState(of hooks: [String: Any]?) -> State {
        guard let bundle = hooks?[geminiHookName] as? [String: Any] else { return .absent }
        let commands = geminiCommands(in: bundle)
        guard !commands.isEmpty else { return .absent }
        guard commands.allSatisfy({ $0.hasPrefix(helperURL.path) }) else { return .stale }
        return geminiEventsMissing(from: bundle).isEmpty ? .installed : .stale
    }

    static func geminiEventsMissing(from bundle: [String: Any]) -> Set<String> {
        let present = geminiEvents.filter { event in
            geminiHandlers(in: bundle[event]).contains { isOurs($0["command"] as? String) }
        }
        return Set(geminiEvents).subtracting(present)
    }

    static func installGemini() throws {
        var hooks = readSettings(geminiHooksURL) ?? [:]
        var bundle: [String: Any] = [:]
        for event in geminiEvents { bundle[event] = geminiEntry(for: event) }
        hooks[geminiHookName] = bundle
        try write(hooks, to: geminiHooksURL)
        Log.hooks.info("installed gemini hooks into \(geminiHooksURL.path, privacy: .public)")
    }

    static func uninstallGemini() throws {
        guard var hooks = readSettings(geminiHooksURL), hooks[geminiHookName] != nil else { return }
        hooks[geminiHookName] = nil
        try write(hooks, to: geminiHooksURL)
        Log.hooks.info("removed gemini hooks from \(geminiHooksURL.path, privacy: .public)")
    }

    static func installGeminiAutomaticallyIfAvailable() {
        guard commandIsAvailable("agy") else { return }
        let before = geminiState()
        guard before != .installed else { return }
        do {
            try installGemini()
            setAutomaticNotice(
                before == .absent
                    ? "Gemini hooks installed automatically. Sessions already running keep their old hooks until they restart."
                    : "Gemini hooks updated automatically. Restart any running session for it to be answerable from the island."
            )
        } catch {
            setAutomaticNotice("Gemini hooks need attention: \(error.localizedDescription)")
            Log.hooks.error("automatic Gemini hook install failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// One event's entry, in whichever of the two shapes that event takes.
    static func geminiEntry(for event: String) -> Any {
        let handler: [String: Any] = [
            "type": "command",
            // Quoted because the helper lives inside an app bundle, whose path has
            // spaces in it, and Antigravity runs the command through `sh -c`.
            "command": "\"\(helperURL.path)\" \(event) gemini",
            "timeout": geminiBlockingEvents.contains(event) ? blockingTimeoutSeconds : reportingTimeoutSeconds
        ]
        guard geminiGroupedEvents.contains(event) else { return [handler] }
        return [["matcher": "*", "hooks": [handler]]]
    }

    /// The handlers for one event, whichever shape it was written in.
    private static func geminiHandlers(in value: Any?) -> [[String: Any]] {
        guard let entries = value as? [[String: Any]] else { return [] }
        return entries.flatMap { entry -> [[String: Any]] in
            if let grouped = entry["hooks"] as? [[String: Any]] { return grouped }
            return [entry]
        }
    }

    private static func geminiCommands(in bundle: [String: Any]) -> [String] {
        bundle.values
            .flatMap { geminiHandlers(in: $0) }
            .compactMap { $0["command"] as? String }
            .filter(isOurs)
            .map { $0.hasPrefix("\"") ? String($0.dropFirst().prefix(while: { $0 != "\"" })) : $0 }
    }

    /// A `notify` line this app wrote. A foreign top-level `notify` is backed up
    /// and remembered before automatic installation replaces it, so removing our
    /// hook restores the original command.
    static func isOurNotifyLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("notify") else { return false }
        guard let equals = trimmed.firstIndex(of: "=") else { return false }
        guard trimmed[trimmed.startIndex..<equals].trimmingCharacters(in: .whitespaces) == "notify" else { return false }
        return trimmed.contains("limitisland-hook")
    }

    private static func isTopLevelNotifyLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.hasPrefix("#"), let equals = trimmed.firstIndex(of: "=") else { return false }
        return trimmed[..<equals].trimmingCharacters(in: .whitespaces) == "notify"
    }

    private static func rememberReplacedCodexNotify(_ line: String) throws {
        try FileManager.default.createDirectory(at: HookServer.supportDirectory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(ReplacedCodexNotify(line: line))
        try data.write(to: replacedCodexNotifyURL, options: .atomic)
    }

    private static func replacedCodexNotify() -> ReplacedCodexNotify? {
        guard let data = try? Data(contentsOf: replacedCodexNotifyURL) else { return nil }
        return try? JSONDecoder().decode(ReplacedCodexNotify.self, from: data)
    }

    private static func setAutomaticNotice(_ notice: String) {
        UserDefaults.standard.set(notice, forKey: DefaultsKey.automaticNotice)
    }

    // MARK: - Shapes

    static func matcherEntry(for event: String) -> [String: Any] {
        let blocking = event == "PreToolUse" || event == "PermissionRequest"
        var entry: [String: Any] = [
            "hooks": [[
                "type": "command",
                "command": "\"\(helperURL.path)\" \(event) claude",
                "timeout": blocking ? blockingTimeoutSeconds : reportingTimeoutSeconds
            ]]
        ]
        // Only the tool-scoped events take a matcher; giving one to SessionStart
        // would be meaningless and is not part of the schema.
        if event == "PreToolUse" || event == "PermissionRequest" || event == "PostToolUse" {
            entry["matcher"] = "*"
        }
        return entry
    }

    /// Strips our hook commands out of one matcher entry, returning nil when
    /// nothing of the user's is left in it.
    private static func pruneOurHooks(from entry: [String: Any]) -> [String: Any]? {
        guard let hooks = entry["hooks"] as? [[String: Any]] else { return entry }
        let kept = hooks.filter { !isOurs($0["command"] as? String) }
        if kept.isEmpty { return nil }
        var updated = entry
        updated["hooks"] = kept
        return updated
    }

    /// Matches by helper *name* rather than full path, so an install from an older
    /// location is still recognised as ours and cleaned up.
    private static func isOurs(_ command: String?) -> Bool {
        command?.contains("limitisland-hook") == true
    }

    /// Our helper commands across every event, or within one named event when
    /// `event` is given — which is how `codexState` tells a complete install from
    /// one that predates the question hook.
    private static func ourCommands(in hooks: [String: Any], event: String? = nil) -> [String] {
        let entries = event.map { [hooks[$0]].compactMap { $0 } } ?? Array(hooks.values)
        return entries
            .compactMap { $0 as? [[String: Any]] }
            .flatMap { $0 }
            .compactMap { $0["hooks"] as? [[String: Any]] }
            .flatMap { $0 }
            .compactMap { $0["command"] as? String }
            .filter(isOurs)
            // The command is quoted, so compare against the path inside the quotes.
            .map { $0.hasPrefix("\"") ? String($0.dropFirst().prefix(while: { $0 != "\"" })) : $0 }
    }

    // MARK: - Files

    private static func readSettings(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func write(_ settings: [String: Any], to url: URL) throws {
        try backUp(url)
        let data = try JSONSerialization.data(
            withJSONObject: settings,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try write(data, to: url)
    }

    private static func write(_ text: String, to url: URL) throws {
        try write(Data(text.utf8), to: url)
    }

    private static func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // Write beside the target so the rename stays on one filesystem and is
        // therefore atomic; `Data.write(options: .atomic)` does the same thing, but
        // this way the temporary file is never left in a different directory.
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".limitisland-settings-\(UUID().uuidString)")
        try data.write(to: temporary)
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: url)
        }
    }

    /// Keeps every backup. They are a few hundred bytes each and the one time they
    /// matter is the one time they were pruned.
    @discardableResult
    static func backUp(_ url: URL) throws -> URL? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let directory = HookServer.supportDirectory.appendingPathComponent("backups")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter.backupNaming.string(from: .now)
        let destination = directory.appendingPathComponent("\(url.lastPathComponent).\(stamp).bak")
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: url, to: destination)
        return destination
    }

    static var backupsDirectory: URL {
        HookServer.supportDirectory.appendingPathComponent("backups")
    }
}

private extension ISO8601DateFormatter {
    /// Colons are legal in a macOS filename but read as path separators in the
    /// Finder, so the timestamp drops them.
    nonisolated(unsafe) static let backupNaming: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withYear, .withMonth, .withDay, .withTime]
        formatter.timeZone = .current
        return formatter
    }()
}
