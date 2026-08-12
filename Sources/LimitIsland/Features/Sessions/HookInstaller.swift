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
        guard commandIsAvailable("claude"), state() != .installed else { return }
        do {
            try install()
            setAutomaticNotice("Claude hooks installed automatically.")
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
        guard let settings = readSettings(claudeSettingsURL),
              let hooks = settings["hooks"] as? [String: Any] else { return .absent }
        let commands = ourCommands(in: hooks)
        guard !commands.isEmpty else { return .absent }
        let expected = helperURL.path
        return commands.allSatisfy { $0.hasPrefix(expected) } ? .installed : .stale
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

    static func codexState() -> State {
        guard let contents = try? String(contentsOf: codexConfigURL, encoding: .utf8) else { return .absent }
        guard let line = contents
            .components(separatedBy: .newlines)
            .first(where: { isOurNotifyLine($0) }) else { return .absent }
        return line.contains(helperURL.path) ? .installed : .stale
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
        Log.hooks.info("removed codex notify from \(codexConfigURL.path, privacy: .public)")
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
        let blocking = event == "PreToolUse"
        var entry: [String: Any] = [
            "hooks": [[
                "type": "command",
                "command": "\"\(helperURL.path)\" \(event) claude",
                "timeout": blocking ? blockingTimeoutSeconds : reportingTimeoutSeconds
            ]]
        ]
        // Only the tool-scoped events take a matcher; giving one to SessionStart
        // would be meaningless and is not part of the schema.
        if event == "PreToolUse" || event == "PostToolUse" {
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

    private static func ourCommands(in hooks: [String: Any]) -> [String] {
        hooks.values
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
