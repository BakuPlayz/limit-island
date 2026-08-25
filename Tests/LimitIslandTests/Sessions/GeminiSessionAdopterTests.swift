import Foundation
import Testing
@testable import LimitIsland

/// A live `agy` holds its conversation's presence lock open. Stale lock files
/// outlive the sessions that made them, so the open file is the evidence and the
/// directory listing is not.
@Suite("Antigravity session adoption")
struct GeminiSessionAdopterTests {
    private let home = NSHomeDirectory()

    @Test("The conversation is read from the lock the process holds")
    func conversationFromOpenLock() {
        let files = [
            "\(home)/.gemini/antigravity-cli/log/cli-20260816_162544.log",
            "\(home)/.gemini/antigravity-cli/knowledge/knowledge.lock",
            "\(home)/.gemini/antigravity-cli/presence/eaff8a8f-15c8-4e4b-983e-52a4793d4145.lock",
            "\(home)/Documents/Github/vibe-usage"
        ]
        #expect(
            GeminiSessionAdopter.conversationID(openFiles: files)
                == "eaff8a8f-15c8-4e4b-983e-52a4793d4145"
        )
    }

    @Test("Antigravity's other locks are not sessions")
    func otherLocksIgnored() {
        // `knowledge.lock` sits outside `presence/` and is not named for a UUID;
        // either test alone would let one of these through.
        #expect(GeminiSessionAdopter.conversationID(openFiles: [
            "\(home)/.gemini/antigravity-cli/knowledge/knowledge.lock",
            "\(home)/.gemini/antigravity-cli/presence/not-a-uuid.lock"
        ]) == nil)
    }

    @Test("A process holding no conversation is not adopted")
    func noLock() {
        #expect(GeminiSessionAdopter.conversationID(openFiles: []) == nil)
        #expect(GeminiSessionAdopter.conversationID(openFiles: ["/dev/null"]) == nil)
    }

    /// The id has to be the one the CLI will use in its own hook payloads, or the
    /// session's next turn would arrive as a second row beside this one.
    @Test("The adopted id is the conversation id the hooks send")
    func idMatchesHookPayload() throws {
        let files = ["\(home)/.gemini/antigravity-cli/presence/6d62b653-00bd-4359-a52f-5908c59d14c9.lock"]
        let adopted = GeminiSessionAdopter.conversationID(openFiles: files)
        let event = try JSONDecoder().decode(HookEvent.self, from: Data("""
        {"event":"PreInvocation","cli":"gemini",
         "payload":{"conversationId":"6d62b653-00bd-4359-a52f-5908c59d14c9"},
         "env":{},"pids":[],"tty":"","sentAt":0}
        """.utf8))
        #expect(adopted == event.sessionID)
    }
}
