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
}
