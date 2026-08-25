import Foundation
import Testing
@testable import LimitIsland

/// Fixtures are trimmed copies of real lines from `~/.codex/sessions`. The format is
/// undocumented, so these are the record of what it looked like when this was
/// written — if Codex changes it, these fail rather than the panel quietly emptying.
@Suite("Codex rollout parsing")
struct CodexRolloutParserTests {
    private func record(_ json: String) -> CodexRolloutParser.Record? {
        CodexRolloutParser.record(from: Data(json.utf8))
    }

    @Test("The session opens with its id and directory")
    func sessionMeta() {
        let line = """
        {"timestamp":"2026-08-11T16:06:49.361Z","type":"session_meta","payload":{
        "session_id":"019ff192-4b71-7521-bce1-12a7b0919ceb","cwd":"/Users/me/Code/thing"}}
        """
        #expect(record(line) == .started(
            sessionID: "019ff192-4b71-7521-bce1-12a7b0919ceb",
            workingDirectory: "/Users/me/Code/thing",
            source: .unknown
        ))
    }

    @Test("Internal Codex rollouts identify themselves as subagents")
    func subagentSource() {
        let line = #"{"type":"session_meta","payload":{"id":"child","cwd":"/tmp/x","source":{"subagent":{"role":"reviewer"}}}}"#
        #expect(record(line) == .started(sessionID: "child", workingDirectory: "/tmp/x", source: .subagent))
    }

    @Test("A user message becomes the row's title")
    func userMessage() {
        let line = #"{"type":"event_msg","payload":{"type":"user_message","message":"fix the auth bug"}}"#
        #expect(record(line) == .prompt("fix the auth bug"))
    }

    @Test("Turn boundaries are recognised")
    func turns() {
        #expect(record(#"{"type":"event_msg","payload":{"type":"task_started","turn_id":"t"}}"#) == .turnStarted)
        #expect(record(#"{"type":"event_msg","payload":{"type":"task_complete","turn_id":"t"}}"#) == .turnCompleted)
    }

    @Test("A shell call reads as the command it runs")
    func execCommand() {
        let line = """
        {"type":"response_item","payload":{"type":"custom_tool_call","name":"exec",
        "input":"const r = await tools.exec_command({\\"cmd\\":[\\"bash\\",\\"-lc\\",\\"npm test\\"]})"}}
        """
        #expect(record(line) == .activity("Running npm test"))
    }

    @Test("A tool call that is not exec says nothing rather than guessing")
    func otherToolCall() {
        let line = #"{"type":"response_item","payload":{"type":"custom_tool_call","name":"something_else","input":"{}"}}"#
        #expect(record(line) == nil)
    }

    @Test("A Codex question becomes a waiting prompt with its visible text")
    func question() {
        let line = #"{"type":"response_item","payload":{"type":"function_call","name":"request_user_input","arguments":"{\"questions\":[{\"header\":\"Side\",\"question\":\"Which side should it use?\",\"options\":[{\"label\":\"Left\",\"description\":\"Use left\"},{\"label\":\"Right\",\"description\":\"Use right\"}],\"multiSelect\":false}]}"}}"#
        let question = AgentQuestion(items: [.init(
            question: "Which side should it use?", header: "Side",
            options: [.init(label: "Left", description: "Use left"), .init(label: "Right", description: "Use right")],
            multiSelect: false
        )])
        #expect(record(line) == .question(question))
        #expect(CodexRolloutParser.question(in: "{}") == nil)
    }

    @Test("A function output proves the terminal answered a question")
    func functionAnswer() {
        #expect(record(#"{"type":"response_item","payload":{"type":"function_call_output","call_id":"call_question","output":"{\"answers\":{\"Choose\":{\"answers\":[\"One\"]}}}"}}"#) == .functionAnswered)
        #expect(record(#"{"type":"response_item","payload":{"type":"function_call_output","output":"{}"}}"#) == nil)
    }

    @Test("A patch summary names the file, or counts them")
    func patchApply() {
        let one = """
        {"type":"event_msg","payload":{"type":"patch_apply_end",
        "stdout":"Success. Updated the following files:\\nM Sources/LimitIsland/Core/Meter.swift"}}
        """
        #expect(record(one) == .activity("Editing Meter.swift"))

        let many = """
        {"type":"event_msg","payload":{"type":"patch_apply_end",
        "stdout":"Success. Updated the following files:\\nA Package.swift\\nA README.md\\nM Sources/x.swift"}}
        """
        #expect(record(many) == .activity("Editing 3 files"))
    }

    @Test("Codex's approval policy maps onto the shared permission mode")
    func approvalPolicy() {
        func mode(_ policy: String) -> CodexRolloutParser.Record? {
            record("""
            {"type":"event_msg","payload":{"type":"thread_settings_applied",
            "thread_settings":{"approval_policy":"\(policy)"}}}
            """)
        }
        // `never` is Codex's auto mode: it has already been told not to ask.
        #expect(mode("never") == .approvalPolicy(.bypass))
        #expect(mode("on-request") == .approvalPolicy(.standard))
        #expect(mode("untrusted") == .approvalPolicy(.standard))
        #expect(record(#"{"type":"turn_context","payload":{"approval_policy":"never"}}"#) == .approvalPolicy(.bypass))
    }

    @Test("The lines that carry the policy carry the model too")
    func model() {
        func model(_ json: String) -> String? {
            CodexRolloutParser.model(from: Data(json.utf8))
        }
        let context = #"{"type":"turn_context","payload":{"approval_policy":"never","model":"gpt-5.6-sol"}}"#
        // Read separately from the record: one line, two things worth knowing, and a
        // record can only be one of them.
        #expect(model(context) == "gpt-5.6-sol")
        #expect(record(context) == .approvalPolicy(.bypass))

        let settings = """
        {"type":"event_msg","payload":{"type":"thread_settings_applied",
        "thread_settings":{"approval_policy":"on-request","model":"gpt-5.6-codex"}}}
        """
        #expect(model(settings) == "gpt-5.6-codex")
        #expect(record(settings) == .approvalPolicy(.standard))

        #expect(model(#"{"type":"event_msg","payload":{"type":"task_started"}}"#) == nil)
        #expect(model("not json at all") == nil)
    }

    @Test("The noisy majority of records are ignored")
    func ignoredRecords() {
        // Reasoning and token counts outnumber everything else in a real file; a
        // parser that reacted to them would flicker the panel constantly.
        #expect(record(#"{"type":"response_item","payload":{"type":"reasoning","summary":[]}}"#) == nil)
        #expect(record(#"{"type":"event_msg","payload":{"type":"token_count","info":{}}}"#) == nil)
        #expect(record(#"{"type":"world_state","payload":{"full":true}}"#) == nil)
        #expect(record("not json at all") == nil)
        #expect(record("{}") == nil)
    }

    @Test("The session id is recoverable from the file name")
    func sessionIDFromFileName() {
        let url = URL(fileURLWithPath: "/x/rollout-2026-08-11T18-05-24-019ff192-4b71-7521-bce1-12a7b0919ceb.jsonl")
        #expect(CodexSessionWatcher.sessionID(fromFileName: url) == "019ff192-4b71-7521-bce1-12a7b0919ceb")
        // Anything that is not a UUID must not be invented into a session.
        #expect(CodexSessionWatcher.sessionID(fromFileName: URL(fileURLWithPath: "/x/rollout-nonsense.jsonl")) == nil)
    }

    @Test("Command extraction survives a missing or malformed wrapper")
    func commandExtractionIsDefensive() {
        #expect(CodexRolloutParser.command(in: "") == nil)
        #expect(CodexRolloutParser.command(in: #"{"cmd":"#) == nil)
        #expect(CodexRolloutParser.command(in: #"{"cmd":["ls"]}"#) == "ls")
    }
}

@Suite("Codex config editing")
struct CodexInstallerTests {
    @Test("Our notify line is recognised; someone else's is not")
    func recognisesOwnLine() {
        #expect(HookInstaller.isOurNotifyLine(HookInstaller.codexNotifyLine()))
        // A `notify` the user wrote themselves is theirs. Replacing or removing it
        // would silently disable their own tooling.
        #expect(!HookInstaller.isOurNotifyLine(#"notify = ["/usr/local/bin/my-notifier"]"#))
        // A commented-out line is not configuration and must not be rewritten.
        #expect(!HookInstaller.isOurNotifyLine("# notify = [\"limitisland-hook\"]"))
        // `notify_style` merely starts with the same letters.
        #expect(!HookInstaller.isOurNotifyLine("notify_style = \"none\""))
        #expect(!HookInstaller.isOurNotifyLine("[projects.\"/Users/me/x\"]"))
    }

    @Test("The notify line is valid TOML naming the helper")
    func lineShape() {
        let line = HookInstaller.codexNotifyLine()
        #expect(line.hasPrefix("notify = ["))
        #expect(line.hasSuffix("]"))
        #expect(line.contains("limitisland-hook"))
        #expect(line.contains("\"notify\""))
    }
}
