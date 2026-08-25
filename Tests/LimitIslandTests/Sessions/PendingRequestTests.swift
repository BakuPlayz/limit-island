import Foundation
import Testing
@testable import LimitIsland

@Suite("Pending requests")
@MainActor
struct PendingRequestTests {
    /// Captures what the CLI would have been sent.
    private final class Answer {
        var reply: HookReply?
        var reason: String?
    }

    private func request(
        provider: Provider,
        tool: String,
        input: JSONValue?,
        into answer: Answer
    ) -> PendingRequest {
        PendingRequest(sessionID: "s", provider: provider, tool: tool, input: input) { reply, reason in
            answer.reply = reply
            answer.reason = reason
        }
    }

    private let codexInput: JSONValue = .object([
        "questions": .array([
            .object([
                "id": .string("scope"),
                "question": .string("How far?"),
                "options": .array([.object(["label": .string("All")])])
            ])
        ])
    ])

    @Test("Codex's question tool gets a question card, like Claude's")
    func questionKind() {
        let answer = Answer()
        let codex = request(provider: .openAI, tool: "request_user_input", input: codexInput, into: answer)
        guard case let .question(parsed) = codex.kind else {
            Issue.record("expected a question")
            return
        }
        #expect(parsed?.items.first?.key == "scope")
    }

    /// Codex cannot be handed an answer the way Claude can. Refusing the call is what
    /// stops it drawing its own picker, and the reason is the only route to the model.
    @Test("A Codex answer is a refusal carrying the answers")
    func codexAnswerIsADenialWithReason() async throws {
        let answer = Answer()
        let codex = request(provider: .openAI, tool: "request_user_input", input: codexInput, into: answer)
        try await Task.sleep(for: .milliseconds(500)) // past the deliberation guard
        codex.answer(["How far?": "All"])

        #expect(codex.isResolved)
        #expect(answer.reply?.decision == .deny)
        #expect(answer.reply?.updatedInput == nil)
        let reason = try #require(answer.reason)
        #expect(reason.hasPrefix(CodexAnswerText.preamble))
        // Codex's own id, not the question text — that is the key its answer payload
        // uses and the one the model already associates with the question.
        #expect(reason.contains("scope: All"))
        #expect(!reason.contains("How far?: All"))
    }

    @Test("A Claude answer is still handed over as the tool's own input")
    func claudeAnswerIsStillAnAllow() async throws {
        let answer = Answer()
        let input: JSONValue = .object(["questions": .array([])])
        let claude = request(provider: .claude, tool: "AskUserQuestion", input: input, into: answer)
        try await Task.sleep(for: .milliseconds(500))
        claude.answer(["Which?": "That one"])

        #expect(answer.reply?.decision == .allow)
        let updated = try #require(answer.reply?.updatedInput)
        #expect(updated["answers"]?["Which?"] == .string("That one"))
    }

    /// A timeout, a quit, or the person choosing the terminal must hand the decision
    /// back rather than answer on their behalf — for Codex that is also the only way
    /// its own picker ever appears.
    @Test("Deferring says nothing at all")
    func deferSaysNothing() {
        let answer = Answer()
        let codex = request(provider: .openAI, tool: "request_user_input", input: codexInput, into: answer)
        codex.defer_()
        #expect(codex.isResolved)
        #expect(answer.reply?.decision == nil)
        #expect(answer.reason == nil)
    }

    @Test("An answer arriving faster than a person leaves the CLI waiting")
    func tooFastIsRefused() {
        let answer = Answer()
        let codex = request(provider: .openAI, tool: "request_user_input", input: codexInput, into: answer)
        codex.answer(["How far?": "All"])
        #expect(!codex.isResolved)
        #expect(answer.reply == nil)
    }
}
