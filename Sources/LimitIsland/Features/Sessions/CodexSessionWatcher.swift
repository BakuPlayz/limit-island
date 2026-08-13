import Foundation

/// Follows Codex's session rollout files and reports what it finds.
///
/// Codex cannot be hooked the way Claude Code can — its only hook fires when a turn
/// ends — so live activity comes from tailing the transcript it writes as it works.
/// The watcher polls rather than using FSEvents: it is one `stat` per known file
/// every couple of seconds, which is cheaper than the machinery for watching a tree
/// that gains a directory every day, and it cannot miss an event by coalescing.
@MainActor
final class CodexSessionWatcher {
    /// Called with everything one line said, in order.
    typealias Sink = @MainActor (CodexSessionWatcher.Update) -> Void

    struct Update {
        let sessionID: String
        let record: CodexRolloutParser.Record
        let workingDirectory: String?
    }

    static var sessionsDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/sessions")
    }

    /// How often to look for new content. Codex turns take seconds at minimum, so
    /// this is well inside "live" without spinning.
    private static let interval: Duration = .seconds(2)
    /// Files older than this are history, not live sessions, and are never opened.
    private static let horizon: TimeInterval = 6 * 60 * 60

    private var pollTask: Task<Void, Never>?
    private var startedAt = Date.distantPast
    /// How far into each file we have already read.
    private var offsets: [URL: UInt64] = [:]
    /// Working directory per session, remembered from `session_meta`.
    private var directories: [String: String] = [:]
    /// Which session each file belongs to, so later lines can be attributed.
    private var sessionForFile: [URL: String] = [:]
    /// Files proven to be internal Codex workers are never allowed to create rows.
    private var ignoredFiles: Set<URL> = []

    private let sink: Sink

    init(sink: @escaping Sink) {
        self.sink = sink
    }

    func start() {
        stop()
        startedAt = .now
        // Replay the bounded recent set once. This is what restores a Codex tab
        // that is already idle when Limit Island launches; seeding at EOF made it
        // invisible until the user submitted another prompt.
        for url in recentFiles(requireLiveProcess: true) {
            offsets[url] = 0
        }
        poll()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.poll()
                try? await Task.sleep(for: Self.interval)
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: - Polling

    private func poll() {
        for url in recentFiles(requireLiveProcess: false) {
            let size = fileSize(url)
            let start = offsets[url] ?? 0
            guard size > start else {
                // A file that shrank was rotated or replaced; start over from zero.
                if size < start { offsets[url] = 0 }
                continue
            }
            offsets[url] = size
            for line in read(url, from: start, to: size) {
                emit(line, from: url)
            }
        }
    }

    private func emit(_ line: Data, from url: URL) {
        guard !ignoredFiles.contains(url) else { return }
        guard let record = CodexRolloutParser.record(from: line) else { return }

        if case let .started(sessionID, directory, source) = record {
            guard source != .subagent else {
                ignoredFiles.insert(url)
                sessionForFile[url] = nil
                return
            }
            sessionForFile[url] = sessionID
            if let directory { directories[sessionID] = directory }
        }
        // A file whose `session_meta` we never saw — because it existed before we
        // started — is attributed by its name, which embeds the session id.
        let sessionID = sessionForFile[url] ?? Self.sessionID(fromFileName: url)
        guard let sessionID else { return }
        sessionForFile[url] = sessionID

        sink(Update(
            sessionID: sessionID,
            record: record,
            workingDirectory: directories[sessionID]
        ))
    }

    /// `rollout-2026-08-11T18-05-24-019ff192-4b71-7521-bce1-12a7b0919ceb.jsonl`
    /// ends with the session's UUID.
    nonisolated static func sessionID(fromFileName url: URL) -> String? {
        let name = url.deletingPathExtension().lastPathComponent
        let parts = name.components(separatedBy: "-")
        guard parts.count >= 5 else { return nil }
        let candidate = parts.suffix(5).joined(separator: "-")
        return UUID(uuidString: candidate) != nil ? candidate : nil
    }

    // MARK: - Files

    /// Rollout files touched recently enough to belong to a live session.
    private func recentFiles(requireLiveProcess: Bool) -> [URL] {
        let cutoff = Date.now.addingTimeInterval(-Self.horizon)
        guard let enumerator = FileManager.default.enumerator(
            at: Self.sessionsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var found: [URL] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl",
                  url.lastPathComponent.hasPrefix("rollout-"),
                  let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
                  let modified = values.contentModificationDate,
                  modified > cutoff else { continue }
            // Historical rollouts are replayed only when they can be tied to a
            // currently running root Codex process. A file first observed after
            // startup is naturally live and is admitted by `poll` below.
            let appearedWhileWatching = modified >= startedAt
            if TerminalDiscovery.hasLiveCodexRollout(url) ||
                (!requireLiveProcess && (offsets[url] != nil || appearedWhileWatching)) {
                found.append(url)
            }
        }
        return found
    }

    private func fileSize(_ url: URL) -> UInt64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return 0 }
        return (attributes[.size] as? NSNumber)?.uint64Value ?? 0
    }

    /// Reads the bytes appended since last time, split into lines. A trailing
    /// partial line is left for the next poll by rewinding the offset to the last
    /// newline — half a JSON object parses as nothing and would be lost otherwise.
    private func read(_ url: URL, from start: UInt64, to end: UInt64) -> [Data] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: start)
            guard let data = try handle.read(upToCount: Int(end - start)), !data.isEmpty else { return [] }
            guard let lastNewline = data.lastIndex(of: 0x0A) else {
                offsets[url] = start   // nothing complete yet; read it all again next time
                return []
            }
            offsets[url] = start + UInt64(lastNewline) + 1
            return data[..<lastNewline]
                .split(separator: 0x0A)
                .map { Data($0) }
        } catch {
            Log.hooks.error("could not read a Codex rollout file: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }
}
