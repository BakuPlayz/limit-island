import Foundation
import Testing
@testable import LimitIsland

@Suite("Agent questions")
struct AgentQuestionTests {
    @Test("Questions retain options, descriptions and multi-select")
    func parses() throws {
        let data = Data(#"{"questions":[{"header":"Stack","question":"Which services?","options":[{"label":"API","description":"Backend"},{"label":"Web"}],"multiSelect":true}]}"#.utf8)
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        let question = try #require(AgentQuestion.parse(value))
        #expect(question.items.count == 1)
        #expect(question.items[0].header == "Stack")
        #expect(question.items[0].multiSelect)
        #expect(question.items[0].options[0].description == "Backend")
    }

    @Test("Malformed questions are ignored")
    func malformed() {
        #expect(AgentQuestion.parse(.object([:])) == nil)
        #expect(AgentQuestion.parse(.object(["questions": .array([])])) == nil)
    }

    /// Codex's schema makes `options` nullable. Dropping such a question used to
    /// leave Codex blocked on a card that never appeared.
    @Test("A question with no options is free text rather than nothing")
    func freeText() throws {
        let data = Data(#"{"questions":[{"id":"api_key_name","header":"Name","question":"What should I call it?"}]}"#.utf8)
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        let question = try #require(AgentQuestion.parse(value))
        #expect(question.items[0].isFreeTextOnly)
        #expect(question.items[0].allowsOther)
        #expect(question.items[0].key == "api_key_name")
    }

    @Test("Codex's own question id is the key, and the text stands in without one")
    func keys() throws {
        let data = Data(#"{"questions":[{"id":"scope","question":"How far?","options":[{"label":"All"}]},{"question":"How far?","options":[{"label":"All"}]}]}"#.utf8)
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        let question = try #require(AgentQuestion.parse(value))
        #expect(question.items[0].key == "scope")
        #expect(question.items[1].key == "How far?")
        // Two questions reading identically must stay two rows.
        #expect(question.items[0].id != question.items[1].id)
    }

    @Test("isOther and isSecret are read in either casing")
    func flags() throws {
        let data = Data(#"{"questions":[{"question":"Which?","options":[{"label":"A"}],"isOther":true,"is_secret":true,"multi_select":true}]}"#.utf8)
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        let question = try #require(AgentQuestion.parse(value))
        #expect(question.items[0].allowsOther)
        #expect(question.items[0].isSecret)
        #expect(question.items[0].multiSelect)
    }

    /// The exact payload Codex 0.147 sent through its `PreToolUse` hook.
    @Test("A real Codex question batch parses whole")
    func realCodexBatch() throws {
        let data = Data(#"""
        {"questions":[
          {"header":"Scope","id":"redesign_scope","question":"What would you like me to redesign?",
           "options":[{"label":"Existing UI (Recommended)","description":"Improve an existing screen."},
                      {"label":"New interface","description":"Create a fresh concept."}]},
          {"header":"Style","id":"visual_style","question":"Which visual direction?",
           "options":[{"label":"Clean and refined (Recommended)","description":"Restrained typography."},
                      {"label":"Bold and expressive","description":"Strong contrast."}]}
        ]}
        """#.utf8)
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        let question = try #require(AgentQuestion.parse(value))
        #expect(question.items.count == 2)
        #expect(question.items.map(\.key) == ["redesign_scope", "visual_style"])
        #expect(question.items[1].options.count == 2)
        #expect(!question.items[0].isFreeTextOnly)
    }
}

@Suite("Codex answer text")
struct CodexAnswerTextTests {
    private func question(_ pairs: [(String, String)]) -> AgentQuestion {
        AgentQuestion(items: pairs.map { key, text in
            .init(question: text, header: "H", options: [.init(label: "A", description: nil)],
                  multiSelect: false, key: key)
        })
    }

    @Test("Answers are keyed by Codex's own question ids, in question order")
    func rendersInOrder() {
        let text = CodexAnswerText.render(
            ["Second?": "Two", "First?": "One"],
            for: question([("first", "First?"), ("second", "Second?")])
        )
        #expect(text.hasPrefix(CodexAnswerText.preamble))
        let lines = text.split(separator: "\n").map(String.init)
        #expect(lines.suffix(2) == ["first: One", "second: Two"])
    }

    /// The model is being told its tool was blocked, so the text has to carry the
    /// instruction not to treat re-asking as the recovery.
    @Test("The preamble tells Codex the question was answered and not to repeat it")
    func preamble() {
        #expect(CodexAnswerText.preamble.contains("answered"))
        #expect(CodexAnswerText.preamble.lowercased().contains("do not ask them again"))
    }

    @Test("Unanswered and blank questions are left out, and an empty set still says something")
    func skipsBlanks() {
        let one = CodexAnswerText.render(
            ["First?": "One", "Second?": "   "],
            for: question([("first", "First?"), ("second", "Second?")])
        )
        #expect(one.contains("first: One"))
        #expect(!one.contains("second"))
        #expect(CodexAnswerText.render([:], for: nil) == CodexAnswerText.preamble)
    }

    @Test("Without a parsed question the answers still render under their own keys")
    func withoutQuestion() {
        let text = CodexAnswerText.render(["Which?": "That one"], for: nil)
        #expect(text.contains("Which?: That one"))
    }
}
