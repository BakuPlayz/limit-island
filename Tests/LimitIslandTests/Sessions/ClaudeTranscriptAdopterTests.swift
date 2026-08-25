import Foundation
import Testing
@testable import LimitIsland

@Suite("Claude transcript adoption")
struct ClaudeTranscriptAdopterTests {
    private func transcript(_ lines: [String]) -> Data {
        Data(lines.joined(separator: "\n").utf8)
    }

    @Test("The last thing the person typed becomes the title")
    func lastHumanPrompt() {
        let data = transcript([
            #"{"type":"user","cwd":"/Users/me/thing","message":{"role":"user","content":"first ask"}}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"working"}]}}"#,
            #"{"type":"user","message":{"role":"user","content":"second ask"}}"#
        ])
        let summary = ClaudeTranscriptAdopter.summary(of: data)
        #expect(summary.directory == "/Users/me/thing")
        #expect(summary.lastPrompt == "second ask")
    }

    /// The hook payloads never name the model, so the transcript is the only place
    /// a Claude row can learn what it is running.
    @Test("The newest assistant turn says which model is running")
    func model() {
        let data = transcript([
            #"{"type":"user","cwd":"/Users/me/thing","message":{"role":"user","content":"go"}}"#,
            #"{"type":"assistant","message":{"role":"assistant","model":"claude-sonnet-5","content":[]}}"#,
            #"{"type":"assistant","message":{"role":"assistant","model":"claude-opus-5","content":[]}}"#
        ])
        // A session switched mid-run reports the model it is on now.
        #expect(ClaudeTranscriptAdopter.summary(of: data).model == "claude-opus-5")
    }

    @Test("A transcript with nothing to say about the model says nothing")
    func modelAbsent() {
        let data = transcript([
            #"{"type":"user","cwd":"/Users/me/thing","message":{"role":"user","content":"go"}}"#,
            // A user entry naming a model is not the session's model.
            #"{"type":"user","message":{"role":"user","model":"not-a-model","content":"go on"}}"#
        ])
        #expect(ClaudeTranscriptAdopter.summary(of: data).model == nil)
    }

    /// Claude Code writes far more `user` entries than the person does: tool results,
    /// slash-command envelopes, and caveats inserted on their behalf. A row titled
    /// with any of those would be worse than one titled with its project.
    @Test("Machine-written user entries are not prompts")
    func ignoresMachineEntries() {
        let data = transcript([
            #"{"type":"user","cwd":"/Users/me/thing","message":{"role":"user","content":"the real ask"}}"#,
            #"{"type":"user","isMeta":true,"message":{"role":"user","content":"a caveat"}}"#,
            #"{"type":"user","message":{"role":"user","content":"<command-name>/clear</command-name>"}}"#,
            #"{"type":"user","toolUseResult":{"stdout":""},"message":{"role":"user","content":"tool output"}}"#,
            #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"blocks"}]}}"#
        ])
        #expect(ClaudeTranscriptAdopter.summary(of: data).lastPrompt == "the real ask")
    }

    /// These files run to megabytes, so only the tail is read and it almost always
    /// begins mid-line. Half an object must cost nothing but itself.
    @Test("A tail that starts mid-line still parses")
    func partialFirstLine() {
        let data = transcript([
            #"e":"user","message":{"role":"user","content":"truncated"}}"#,
            #"{"type":"user","cwd":"/Users/me/thing","message":{"role":"user","content":"intact"}}"#
        ])
        let summary = ClaudeTranscriptAdopter.summary(of: data)
        #expect(summary.lastPrompt == "intact")
        #expect(summary.directory == "/Users/me/thing")
    }

    @Test("A transcript with nothing usable yields nothing")
    func emptySummary() {
        #expect(ClaudeTranscriptAdopter.summary(of: Data()) == ClaudeTranscriptAdopter.Summary())
        #expect(ClaudeTranscriptAdopter.summary(of: transcript(["not json at all"])).lastPrompt == nil)
    }

    @Test("The file name is the session id the CLI will use")
    func sessionIDFromFileName() {
        let directory = URL(fileURLWithPath: "/tmp/projects/-Users-me-thing")
        let valid = directory.appendingPathComponent("578f3a4f-4a33-46ce-b4f5-4599f331c584.jsonl")
        #expect(ClaudeTranscriptAdopter.sessionID(fromFileName: valid) == "578f3a4f-4a33-46ce-b4f5-4599f331c584")
        #expect(ClaudeTranscriptAdopter.sessionID(fromFileName: directory.appendingPathComponent("notes.jsonl")) == nil)
    }
}
