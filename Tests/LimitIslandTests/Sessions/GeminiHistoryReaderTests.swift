import Foundation
import Testing
@testable import LimitIsland

/// Fixtures are trimmed copies of real lines from
/// `~/.gemini/antigravity-cli/history.jsonl`.
@Suite("Antigravity history")
struct GeminiHistoryReaderTests {
    private func history(_ lines: [String]) -> Data {
        Data(lines.joined(separator: "\n").utf8)
    }

    @Test("The newest prompt in this conversation becomes the title")
    func newestWins() {
        let data = history([
            #"{"display":"first ask","timestamp":1786890473357,"workspace":"/Users/me/thing","conversationId":"c1"}"#,
            #"{"display":"second ask","timestamp":1786890499000,"workspace":"/Users/me/thing","conversationId":"c1"}"#
        ])
        #expect(GeminiHistoryReader.lastPrompt(in: data, conversationID: "c1") == "second ask")
    }

    @Test("Another conversation's prompt is not this session's title")
    func otherConversationsIgnored() {
        let data = history([
            #"{"display":"mine","timestamp":1,"workspace":"/Users/me/thing","conversationId":"c1"}"#,
            #"{"display":"someone else's","timestamp":2,"workspace":"/Users/me/other","conversationId":"c2"}"#,
            // The CLI also writes entries with no conversation at all.
            #"{"display":"/model","timestamp":3,"workspace":"/Users/me/thing","type":"slash_command"}"#
        ])
        #expect(GeminiHistoryReader.lastPrompt(in: data, conversationID: "c1") == "mine")
    }

    @Test("A slash command is how you drive the CLI, not what you asked it")
    func slashCommandsSkipped() {
        let data = history([
            #"{"display":"fix the auth bug","timestamp":1,"conversationId":"c1"}"#,
            #"{"display":"/model","timestamp":2,"conversationId":"c1","type":"slash_command"}"#
        ])
        #expect(GeminiHistoryReader.lastPrompt(in: data, conversationID: "c1") == "fix the auth bug")
    }

    /// Only the tail of the file is read, and it almost always begins mid-line.
    @Test("A truncated first line costs nothing but itself")
    func truncatedFirstLine() {
        let data = history([
            #"rkspace":"/Users/me/thing","conversationId":"c1"}"#,
            #"{"display":"the whole ask","timestamp":2,"conversationId":"c1"}"#
        ])
        #expect(GeminiHistoryReader.lastPrompt(in: data, conversationID: "c1") == "the whole ask")
    }

    @Test("A session with nothing typed in it yet has no title to take")
    func noMatch() {
        let data = history([#"{"display":"mine","timestamp":1,"conversationId":"c1"}"#])
        #expect(GeminiHistoryReader.lastPrompt(in: data, conversationID: "c9") == nil)
        #expect(GeminiHistoryReader.lastPrompt(in: Data(), conversationID: "c1") == nil)
        #expect(GeminiHistoryReader.lastPrompt(in: Data("not json".utf8), conversationID: "c1") == nil)
    }
}
