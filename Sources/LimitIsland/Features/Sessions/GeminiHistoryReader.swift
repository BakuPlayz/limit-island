import Foundation

/// Reads what the person last typed into the Antigravity CLI.
///
/// `agy` has no prompt hook — its lifecycle events start at `PreInvocation`, by
/// which point the prompt is already the model's problem and not ours — so a
/// Gemini row would have nothing to title itself with but its project directory.
/// The CLI does append every prompt to `~/.gemini/antigravity-cli/history.jsonl`
/// as it is submitted, tagged with the conversation it belongs to, and that is the
/// same identifier the hook payloads carry.
///
/// Parsed leniently and separated from the file reading, like the other transcript
/// readers here: this is another program's private format, and a line it invents
/// tomorrow must cost us nothing more than that line.
enum GeminiHistoryReader {
    static var historyURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".gemini/antigravity-cli/history.jsonl")
    }

    /// The tail is enough: the interesting entry is the newest one, and the file is
    /// a few hundred kilobytes of every prompt ever typed.
    private static let tailBytes = 64 * 1024

    /// Blocking. Call it off the main actor.
    static func lastPrompt(conversationID: String) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: historyURL) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size <= UInt64(tailBytes) ? 0 : size - UInt64(tailBytes)
        guard (try? handle.seek(toOffset: start)) != nil,
              let data = try? handle.readToEnd(), !data.isEmpty else { return nil }
        // A tail almost always begins inside a line. Half a JSON object parses as
        // nothing, but dropping it explicitly keeps the intent clear.
        let complete = start == 0 ? data : data.drop(while: { $0 != 0x0A })
        return lastPrompt(in: Data(complete), conversationID: conversationID)
    }

    /// The newest prompt in `data` belonging to `conversationID`.
    static func lastPrompt(in data: Data, conversationID: String) -> String? {
        var found: String?
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            guard let entry = try? JSONDecoder().decode(JSONValue.self, from: Data(line)),
                  entry.string("conversationId") == conversationID,
                  // `/model` and the rest are how the person drives the CLI, not what
                  // they asked it for. A row titled with one says nothing.
                  entry.string("type") != "slash_command",
                  let prompt = entry.string("display")
            else { continue }
            found = prompt
        }
        return found
    }
}
