import Foundation

/// A Claude Code session that was already running before Limit Island started.
/// An agent session that was already running when the app launched, whichever CLI
/// it belongs to. `GeminiSessionAdopter` produces these too.
struct AdoptedSession: Sendable {
    let sessionID: String
    var provider: Provider = .claude
    let directory: String
    let lastPrompt: String?
    let model: String?
    let startedAt: Date
    let lastEventAt: Date
    let terminal: TerminalRef
}

/// Finds the agents that were already working when the app launched.
///
/// Claude Code only announces itself through hooks, so a session that predates the
/// app — or predates its hooks — is invisible for as long as it runs. Its transcript
/// is not: `~/.claude/projects/<slug>/<session-uuid>.jsonl` is appended to as the
/// agent works, and its name is the session id the CLI will use in its own hook
/// payloads. Reading it once at launch is therefore enough to show the row, and the
/// first real hook event lands on that same row without any merging.
///
/// This is the Claude half of what `CodexSessionWatcher.start()` already does for
/// Codex rollouts, and it takes the same two precautions: a recency horizon, and a
/// live process it can actually point at.
enum ClaudeTranscriptAdopter {
    static var projectsDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/projects")
    }

    /// Transcripts older than this belong to finished work, and are never opened.
    /// Same horizon as the Codex watcher, for the same reason.
    private static let horizon: TimeInterval = 6 * 60 * 60

    /// These files reach tens of megabytes, and a single tool result can be a
    /// megabyte of it, so how far back the last human prompt sits varies wildly.
    /// Read a window from the end, and only widen it when that window turned up no
    /// prompt at all.
    private static let tailWindows = [256 * 1024, 2 * 1024 * 1024, Int.max]

    /// Blocking: `ps`, `lsof` and a read per candidate. Call it off the main actor.
    static func discover(now: Date = .now) -> [AdoptedSession] {
        newestPerProcess(candidates(now: now))
    }

    /// A directory usually holds several recent transcripts — every `/clear` and
    /// every resume starts a new one — and they all resolve to the same live agent.
    /// That agent is one row, and the transcript it is still writing to is the one
    /// that was touched last.
    private static func newestPerProcess(_ found: [AdoptedSession]) -> [AdoptedSession] {
        var newest: [String: AdoptedSession] = [:]
        for candidate in found {
            let identity = candidate.terminal.stableIdentity ?? candidate.sessionID
            if let existing = newest[identity], existing.lastEventAt >= candidate.lastEventAt { continue }
            newest[identity] = candidate
        }
        return Array(newest.values)
    }

    private static func candidates(now: Date) -> [AdoptedSession] {
        recentTranscripts(now: now).compactMap { url in
            guard let sessionID = sessionID(fromFileName: url),
                  let summary = summary(of: url),
                  let directory = summary.directory,
                  // No unique live `claude` in that directory means either the
                  // session is over or two agents share it. Neither can be pointed
                  // at a terminal honestly, so neither becomes a row.
                  let terminal = TerminalDiscovery.cli(named: "claude", in: directory)
            else { return nil }
            let dates = timestamps(of: url)
            return AdoptedSession(
                sessionID: sessionID,
                directory: directory,
                lastPrompt: summary.lastPrompt,
                model: summary.model,
                startedAt: dates.created,
                lastEventAt: dates.modified,
                terminal: terminal
            )
        }
    }

    /// `…/projects/-Users-me-thing/578f3a4f-4a33-46ce-b4f5-4599f331c584.jsonl`
    static func sessionID(fromFileName url: URL) -> String? {
        let name = url.deletingPathExtension().lastPathComponent
        return UUID(uuidString: name) != nil ? name : nil
    }

    // MARK: - Parsing

    struct Summary: Equatable {
        var directory: String?
        var lastPrompt: String?
        /// The model of the newest assistant entry — a session switched mid-run
        /// reports the one it is on now, which is what the row should say.
        var model: String?
    }

    /// The model a live session is running, read from the tail of its transcript.
    ///
    /// Hook payloads name the transcript but never the model, so this is the only
    /// place it can be had for a Claude session. A small window is enough: the
    /// interesting entry is the most recent assistant turn.
    static func model(atPath path: String) -> String? {
        summary(of: URL(fileURLWithPath: path), lastBytes: tailWindows[0])?.model
    }

    /// What the tail of a transcript says about the session. Parsed leniently: this
    /// is another program's private format, and a line it invents tomorrow must cost
    /// us nothing more than that line.
    static func summary(of data: Data) -> Summary {
        var summary = Summary()
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        for line in lines {
            guard let entry = try? JSONDecoder().decode(JSONValue.self, from: Data(line)) else { continue }
            if let directory = entry.string("cwd") { summary.directory = directory }
            if entry.string("type") == "assistant",
               let model = entry["message"]?.string("model") {
                summary.model = model
            }
            guard let prompt = humanPrompt(entry) else { continue }
            summary.lastPrompt = prompt
        }
        return summary
    }

    /// The person's own instruction, as opposed to the many other things Claude Code
    /// writes as a `user` entry: tool results, slash-command envelopes, and the
    /// caveats it inserts on their behalf.
    private static func humanPrompt(_ entry: JSONValue) -> String? {
        guard entry.string("type") == "user",
              entry["isMeta"] != .bool(true),
              entry["toolUseResult"] == nil,
              // A tool result carries an array of blocks; a typed prompt is a string.
              case let .string(text)? = entry["message"]?["content"]
        else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !envelopes.contains(where: trimmed.hasPrefix) else { return nil }
        return trimmed
    }

    /// Machine-written `user` entries. Named rather than matched on a leading `<`,
    /// which would also throw away a prompt that opens with markup.
    private static let envelopes = [
        "<command-name>", "<local-command-caveat>", "<local-command-stdout>",
        "<task-notification>", "<system-reminder>"
    ]

    private static func summary(of url: URL) -> Summary? {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        var widest: Summary?
        for window in tailWindows {
            guard let summary = summary(of: url, lastBytes: window) else { return widest }
            widest = summary
            // Stop at the first window that answered, or once the window covers the
            // whole file and a wider one would read exactly the same bytes.
            if summary.lastPrompt != nil || window >= size { break }
        }
        return widest
    }

    private static func summary(of url: URL, lastBytes: Int) -> Summary? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = lastBytes == .max || size <= UInt64(lastBytes) ? 0 : size - UInt64(lastBytes)
        guard (try? handle.seek(toOffset: start)) != nil,
              let data = try? handle.readToEnd(), !data.isEmpty else { return nil }
        // A window almost always begins inside a line. Half a JSON object parses as
        // nothing, but dropping it explicitly keeps the intent clear.
        let complete = start == 0 ? data : data.drop(while: { $0 != 0x0A })
        return summary(of: Data(complete))
    }

    // MARK: - Files

    private static func recentTranscripts(now: Date) -> [URL] {
        let cutoff = now.addingTimeInterval(-horizon)
        guard let enumerator = FileManager.default.enumerator(
            at: projectsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var found: [URL] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl",
                  let modified = try? url.resourceValues(
                      forKeys: [.contentModificationDateKey]
                  ).contentModificationDate,
                  modified > cutoff else { continue }
            found.append(url)
        }
        return found
    }

    private static func timestamps(of url: URL) -> (created: Date, modified: Date) {
        let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        let modified = values?.contentModificationDate ?? .now
        return (values?.creationDate ?? modified, modified)
    }
}
