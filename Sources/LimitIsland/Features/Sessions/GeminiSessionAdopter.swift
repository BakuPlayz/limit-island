import Foundation

/// Finds the Antigravity sessions that were already working when the app launched.
///
/// `agy` announces itself only through hooks, and only when it does something — so a
/// session that predates Limit Island, or one sitting at its prompt waiting for the
/// person, is invisible until its next turn. This is the Gemini counterpart of
/// `ClaudeTranscriptAdopter`, and it can be more certain than either of the others:
/// a live `agy` holds its conversation's presence lock open, so the process and the
/// session id it will use in its hook payloads are tied together by the process
/// itself rather than inferred from a directory.
///
/// That is also why this does not need Claude's ambiguity guard. Two `agy` sessions
/// in one project are two locks and two rows, not an unanswerable question.
enum GeminiSessionAdopter {
    static var presenceDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".gemini/antigravity-cli/presence")
    }

    static var conversationsDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".gemini/antigravity-cli/conversations")
    }

    /// Blocking: `ps`, an `lsof` per candidate, and a read of the history file.
    /// Call it off the main actor.
    static func discover() -> [AdoptedSession] {
        TerminalDiscovery.liveCLIs(named: "agy").compactMap { process in
            guard let conversationID = conversationID(openFiles: TerminalDiscovery.openFiles(of: process.pid))
            else { return nil }
            let dates = timestamps(of: conversationID)
            return AdoptedSession(
                sessionID: conversationID,
                provider: .gemini,
                directory: process.directory,
                lastPrompt: GeminiHistoryReader.lastPrompt(conversationID: conversationID),
                // Deliberately no model: the CLI's persisted setting is not
                // necessarily this session's, and a wrong badge is worse than none.
                // The first hook event of its next turn fills it in.
                model: nil,
                startedAt: dates.started,
                lastEventAt: dates.lastActive,
                terminal: process.terminal
            )
        }
    }

    /// The conversation a live `agy` is in, read from the presence lock it holds.
    ///
    /// Stale locks outlive the sessions that made them — the file stays, only the
    /// lock on it is released — so the directory listing cannot be trusted on its
    /// own. What a process has *open* can be.
    static func conversationID(openFiles: [String]) -> String? {
        for path in openFiles {
            let url = URL(fileURLWithPath: path)
            guard url.pathExtension == "lock",
                  url.deletingLastPathComponent().lastPathComponent == "presence" else { continue }
            let name = url.deletingPathExtension().lastPathComponent
            // Antigravity keeps other locks of its own; only a conversation's is
            // named for a UUID, and only that name is a session id.
            guard UUID(uuidString: name) != nil else { continue }
            return name
        }
        return nil
    }

    /// When the conversation opened, and when it last did anything. The lock is
    /// created as the conversation opens; the conversation store is written to as
    /// the work happens.
    private static func timestamps(of conversationID: String) -> (started: Date, lastActive: Date) {
        let lock = presenceDirectory.appendingPathComponent("\(conversationID).lock")
        let store = conversationsDirectory.appendingPathComponent("\(conversationID).db")
        let lockValues = try? lock.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        let storeModified = (try? store.resourceValues(
            forKeys: [.contentModificationDateKey]
        ))?.contentModificationDate
        let started = lockValues?.creationDate ?? .now
        return (started, storeModified ?? lockValues?.contentModificationDate ?? started)
    }
}
