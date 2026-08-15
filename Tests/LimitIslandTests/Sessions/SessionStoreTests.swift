import Foundation
import Testing
@testable import LimitIsland

@MainActor
@Suite("Session tracking")
struct SessionStoreTests {
    private func event(
        _ name: String,
        session: String = "s1",
        payload: [String: Any] = [:],
        cli: String = "claude",
        // The second entry is the CLI itself, which is what gives the session a
        // process identity. Left out by default: most tests want rows that stay
        // distinct rather than coalescing on a shared TTY.
        pids: [Int32] = [1]
    ) throws -> HookEvent {
        var body = payload
        body["session_id"] = session
        let frame: [String: Any] = [
            "event": name,
            "cli": cli,
            "payload": body,
            "env": ["TERM_PROGRAM": "iTerm.app"],
            "pids": pids,
            "tty": "/dev/ttys001",
            "sentAt": 0
        ]
        let data = try JSONSerialization.data(withJSONObject: frame)
        return try JSONDecoder().decode(HookEvent.self, from: data)
    }

    /// Waits for a card, then waits out `PendingRequest.minimumDeliberationTime`.
    ///
    /// Answering a card the instant it appears is refused by design — see
    /// `minimumDeliberation` for why — so any test that means to press a button has
    /// to be as slow as a person.
    private func awaitAnswerableCard(in store: SessionStore) async throws -> PendingRequest {
        while store.pending.isEmpty { await Task.yield() }
        let request = store.pending[0]
        try await Task.sleep(for: .milliseconds(Int(PendingRequest.minimumDeliberationTime * 1000) + 80))
        return request
    }

    @Test("A session appears, gains a prompt, runs a tool, and finishes")
    func lifecycle() async throws {
        let store = SessionStore()
        store.approvalMatcher = ""

        _ = await store.handle(try event("SessionStart", payload: ["cwd": "/Users/me/Code/thing"]))
        #expect(store.sessions.count == 1)
        #expect(store.sessions[0].project == "thing")

        _ = await store.handle(try event("UserPromptSubmit", payload: ["prompt": "fix the auth bug in middleware"]))
        #expect(store.sessions[0].title == "fix the auth bug in middleware")
        #expect(store.sessions[0].activity == .thinking)

        _ = await store.handle(try event("PreToolUse", payload: [
            "tool_name": "Edit",
            "tool_input": ["file_path": "/Users/me/Code/thing/src/middleware.ts"]
        ]))
        #expect(store.sessions[0].activity == .running("Editing middleware.ts"))

        _ = await store.handle(try event("Stop"))
        #expect(store.sessions[0].activity == .done)

        _ = await store.handle(try event("SessionEnd"))
        #expect(store.sessions.isEmpty)
    }

    @Test("The most recently active session is listed first")
    func ordering() async throws {
        let store = SessionStore()
        store.approvalMatcher = ""

        _ = await store.handle(try event("SessionStart", session: "a"))
        _ = await store.handle(try event("SessionStart", session: "b"))
        #expect(store.sessions.map(\.id) == ["b", "a"])

        _ = await store.handle(try event("UserPromptSubmit", session: "a", payload: ["prompt": "hello"]))
        #expect(store.sessions.map(\.id) == ["a", "b"])
    }

    @Test("A tool outside the matcher is reported but never intercepted")
    func matcherScoping() async throws {
        let store = SessionStore()
        store.approvalMatcher = "Bash"

        let (reply, _) = await store.handle(try event("PreToolUse", payload: [
            "tool_name": "Read",
            "tool_input": ["file_path": "/tmp/x.txt"]
        ]))
        // No opinion means Claude Code's own permission flow runs untouched, which
        // is the whole reason the matcher exists.
        #expect(reply.decision == nil)
        #expect(store.pending.isEmpty)
    }

    @Test("Auto-accept mode is left alone", arguments: [
        ("acceptEdits", "Edit"),
        ("acceptEdits", "Write"),
        ("bypassPermissions", "Edit"),
        ("bypassPermissions", "Bash")
    ])
    func autoModeIsNotIntercepted(mode: String, tool: String) async throws {
        // Someone running in auto-accept has already answered the question the card
        // would ask. Putting one in front of them would be worse than not running.
        let store = SessionStore()
        let (reply, _) = await store.handle(try event("PreToolUse", payload: [
            "tool_name": tool,
            "permission_mode": mode,
            "tool_input": ["file_path": "/x/a.ts", "command": "ls"]
        ]))
        #expect(reply.decision == nil)
        #expect(store.pending.isEmpty)
        // It is still reported — the point is not to hide the session, only to stop
        // asking about it.
        #expect(store.sessions.count == 1)
    }

    @Test("Claude auto mode never adds notch permission prompts")
    func acceptEditsDoesNotInterrupt() async throws {
        let store = SessionStore()
        let (reply, _) = await store.handle(try event("PreToolUse", payload: [
            "tool_name": "Bash",
            "permission_mode": "acceptEdits",
            "tool_input": ["command": "npm test"]
        ]))
        #expect(reply.decision == nil)
        #expect(store.pending.isEmpty)
    }

    @Test("Codex and Sol auto policy never adds a permission card")
    func codexAutoModeDoesNotInterrupt() async throws {
        let store = SessionStore()
        let (reply, _) = await store.handle(try event(
            "PermissionRequest", session: "cx",
            payload: ["tool_name": "exec", "approval_policy": "never"], cli: "codex"
        ))
        #expect(reply.decision == nil)
        #expect(store.pending.isEmpty)
    }

    @Test("Switching a waiting Codex session to auto mode immediately allows its card")
    func codexAutoModeResolvesExistingCard() async throws {
        let store = SessionStore()
        let waiting = Task {
            await store.handle(try! self.event(
                "PermissionRequest", session: "cx",
                payload: ["tool_name": "exec"], cli: "codex"
            ))
        }
        while store.pending.isEmpty { await Task.yield() }

        store.apply(.init(
            sessionID: "cx", record: .approvalPolicy(.bypass), workingDirectory: "/tmp/x"
        ))

        let (reply, reason) = await waiting.value
        #expect(reply.decision == .allow)
        #expect(reason == "Approved because the session entered auto mode")
        #expect(store.pending.isEmpty)
    }

    @Test("Plan mode surfaces the plan and nothing else")
    func planMode() async throws {
        let store = SessionStore()
        let (reply, _) = await store.handle(try event("PreToolUse", payload: [
            "tool_name": "Edit",
            "permission_mode": "plan",
            "tool_input": ["file_path": "/x/a.ts"]
        ]))
        #expect(reply.decision == nil)
        #expect(store.pending.isEmpty)
    }

    @Test("A decision too fast to be human is refused, and the card stays up")
    func minimumDeliberation() async throws {
        // The reason this exists: a card once resolved itself with the pointer in
        // the opposite corner of the screen and nothing typed. Whatever produced
        // that, it was not someone reading a diff.
        let store = SessionStore()
        store.approvalMatcher = "Bash"
        let pending = Task {
            await store.handle(try! self.event("PreToolUse", payload: [
                "tool_name": "Bash",
                "tool_input": ["command": "rm -rf build"]
            ]))
        }
        while store.pending.isEmpty { await Task.yield() }
        let request = store.pending[0]

        store.allow(request)
        #expect(!request.isResolved, "a decision inside the deliberation window must not take")
        #expect(store.pending.count == 1, "and the card must stay up rather than strand the CLI")

        // After the window, the same press works.
        try await Task.sleep(for: .milliseconds(Int(PendingRequest.minimumDeliberationTime * 1000) + 120))
        store.allow(request)
        let (reply, _) = await pending.value
        #expect(reply.decision == .allow)
        #expect(store.pending.isEmpty)
    }

    @Test("Deferring is never rate-limited")
    func deferralIsImmediate() async throws {
        // Handing a decision back is always safe, and delaying it would hold up a
        // CLI that is waiting on us for no benefit.
        let store = SessionStore()
        store.approvalMatcher = "Bash"
        let pending = Task {
            await store.handle(try! self.event("PreToolUse", payload: [
                "tool_name": "Bash", "tool_input": ["command": "ls"]
            ]))
        }
        while store.pending.isEmpty { await Task.yield() }
        store.stop()
        let (reply, _) = await pending.value
        #expect(reply.decision == nil)
    }

    @Test("The current process is recognised as alive")
    func processLiveness() {
        #expect(TerminalDiscovery.isProcessAlive(getpid()))
    }

    @Test("A Codex transcript builds a session without any hook")
    func codexFromTranscript() {
        let store = SessionStore()
        func apply(_ record: CodexRolloutParser.Record) {
            store.apply(.init(sessionID: "cx", record: record, workingDirectory: "/Users/me/Code/thing"))
        }
        apply(.started(sessionID: "cx", workingDirectory: "/Users/me/Code/thing", source: .user))
        #expect(store.sessions.count == 1)
        #expect(store.sessions[0].provider == .openAI)
        #expect(store.sessions[0].project == "thing")

        apply(.prompt("optimise the queries"))
        #expect(store.sessions[0].title == "optimise the queries")

        apply(.activity("Running npm test"))
        #expect(store.sessions[0].activity == .running("Running npm test"))

        apply(.turnCompleted)
        #expect(store.sessions[0].activity == .done)
    }

    @Test("A terminal-side Codex function answer clears its question")
    func codexFunctionAnswerClearsQuestion() {
        let store = SessionStore()
        let question = AgentQuestion(items: [.init(
            question: "Choose", header: "Choice",
            options: [.init(label: "One", description: nil)], multiSelect: false
        )])
        store.apply(.init(sessionID: "cx", record: .question(question), workingDirectory: "/tmp/x"))
        #expect(store.activeInteraction != nil)
        store.apply(.init(sessionID: "cx", record: .functionAnswered, workingDirectory: "/tmp/x"))
        #expect(store.activeInteraction == nil)
        #expect(store.session(id: "cx")?.activity == .thinking)
    }

    @Test("Internal Codex transcripts never create sessions")
    func ignoresCodexSubagents() {
        let store = SessionStore()
        store.apply(.init(
            sessionID: "child",
            record: .started(sessionID: "child", workingDirectory: "/tmp/x", source: .subagent),
            workingDirectory: "/tmp/x"
        ))
        #expect(store.sessions.isEmpty)
    }

    @Test("An exact terminal identity coalesces stale and live rows")
    func coalescesExactTerminalIdentity() {
        let store = SessionStore()
        store.apply(.init(sessionID: "old", record: .prompt("useful prompt"), workingDirectory: "/tmp/x"))
        store.apply(.init(sessionID: "live", record: .turnStarted, workingDirectory: "/tmp/x"))
        let terminal = TerminalRef(program: "iTerm.app", tty: "/dev/ttys001", workingDirectory: "/tmp/x", agentPID: 4242, pids: [4242])
        store.attachCodexTerminal(terminal, sessionID: "old", workingDirectory: "/tmp/x")
        store.attachCodexTerminal(terminal, sessionID: "live", workingDirectory: "/tmp/x")
        #expect(store.sessions.map(\.id) == ["live"])
        #expect(store.sessions[0].lastPrompt == "useful prompt")
    }

    @Test("A resumed Claude session replaces its stale row instead of adding one")
    func coalescesResumedClaudeSession() async throws {
        let store = SessionStore()
        store.approvalMatcher = ""
        _ = await store.handle(try event("SessionStart", session: "old", pids: [1, 4242]))
        _ = await store.handle(try event(
            "UserPromptSubmit", session: "old",
            payload: ["prompt": "useful prompt"], pids: [1, 4242]
        ))
        _ = await store.handle(try event("SessionStart", session: "live", pids: [1, 4242]))
        #expect(store.sessions.map(\.id) == ["live"])
        #expect(store.sessions[0].lastPrompt == "useful prompt")
    }

    @Test("Two Claude agents in separate processes stay separate rows")
    func keepsDistinctClaudeProcesses() async throws {
        let store = SessionStore()
        store.approvalMatcher = ""
        _ = await store.handle(try event("SessionStart", session: "one", pids: [1, 1001]))
        _ = await store.handle(try event("SessionStart", session: "two", pids: [1, 1002]))
        #expect(store.sessions.count == 2)
    }

    @Test("Matching titles in distinct processes remain distinct sessions")
    func preservesDistinctProcesses() {
        let store = SessionStore()
        for id in ["one", "two"] {
            store.apply(.init(sessionID: id, record: .prompt("same title"), workingDirectory: "/tmp/x"))
        }
        store.attachCodexTerminal(
            TerminalRef(program: nil, tty: "/dev/ttys001", workingDirectory: "/tmp/x", agentPID: 1001, pids: [1001]),
            sessionID: "one", workingDirectory: "/tmp/x"
        )
        store.attachCodexTerminal(
            TerminalRef(program: nil, tty: "/dev/ttys001", workingDirectory: "/tmp/x", agentPID: 1002, pids: [1002]),
            sessionID: "two", workingDirectory: "/tmp/x"
        )
        #expect(store.sessions.count == 2)
    }

    @Test("A chosen terminal destination is remembered only on its live session")
    func remembersTerminalDestination() async throws {
        let store = SessionStore()
        store.approvalMatcher = ""
        _ = await store.handle(try event("SessionStart", session: "a"))
        let destination = TerminalDestination(
            kind: .ghostty, stableID: "one", terminalName: "Ghostty",
            title: "tab", workingDirectory: "/tmp/project"
        )
        store.selectDestination(destination, for: "a")
        #expect(store.session(id: "a")?.selectedDestination == destination)
        store.removeSession("a")
        #expect(store.session(id: "a") == nil)
    }

    @Test("Sessions waiting on the user sort above the rest")
    func waitingSortsFirst() async throws {
        let store = SessionStore()
        store.approvalMatcher = ""
        _ = await store.handle(try event("SessionStart", session: "a"))
        _ = await store.handle(try event("SessionStart", session: "b"))
        _ = await store.handle(try event("Notification", session: "a", payload: [
            "message": "needs you", "notification_type": "permission_prompt"
        ]))
        // `b` is more recent, but `a` is the one that cannot continue without you.
        #expect(store.sessions.first?.id == "a")
        #expect(store.isWaitingOnUser)
    }

    @Test("A notification says the CLI is waiting rather than leaving it looking stalled")
    func notificationSurfaces() async throws {
        let store = SessionStore()
        store.approvalMatcher = ""
        _ = await store.handle(try event("SessionStart"))
        _ = await store.handle(try event("Notification", payload: [
            "message": "Claude needs your permission to use Bash",
            "notification_type": "permission_prompt"
        ]))
        #expect(store.sessions[0].activity == .waitingInTerminal("Claude needs your permission to use Bash"))
        #expect(store.sessions[0].activity.isWaiting)
    }

    @Test("Claude idle and passive notifications do not falsely request input")
    func nonInteractiveNotifications() async throws {
        let store = SessionStore()
        store.approvalMatcher = ""
        _ = await store.handle(try event("SessionStart"))
        _ = await store.handle(try event("Notification", payload: [
            "message": "Claude is waiting for your input", "notification_type": "idle_prompt"
        ]))
        #expect(store.sessions[0].activity == .done)
        #expect(!store.isWaitingOnUser)

        _ = await store.handle(try event("Notification", payload: [
            "message": "Signed in", "notification_type": "auth_success"
        ]))
        #expect(store.sessions[0].activity == .done)
    }

    @Test("Synthetic task notifications never replace the real Claude prompt")
    func ignoresTaskNotificationPrompts() async throws {
        let store = SessionStore()
        store.approvalMatcher = ""
        _ = await store.handle(try event("UserPromptSubmit", payload: ["prompt": "real request"]))
        _ = await store.handle(try event("UserPromptSubmit", payload: [
            "prompt": "<task-notification>\n<status>completed</status>\n</task-notification>"
        ]))
        #expect(store.sessions.count == 1)
        #expect(store.sessions[0].lastPrompt == "real request")
    }

    @Test("Stopping the app releases anything still waiting, rather than hanging an agent")
    func stopReleasesPending() async throws {
        let store = SessionStore()
        store.approvalMatcher = "Bash"

        let pending = Task {
            await store.handle(try! self.event("PreToolUse", payload: [
                "tool_name": "Bash",
                "tool_input": ["command": "rm -rf build"]
            ]))
        }
        // Let the handler reach the point of publishing a card.
        while store.pending.isEmpty { await Task.yield() }
        #expect(store.sessions.first?.activity == .awaitingDecision)

        store.stop()
        let (reply, _) = await pending.value
        // Never a denial on the way out: the CLI must be free to ask for itself.
        #expect(reply.decision == nil)
    }

    @Test("Allowing resolves the card exactly once")
    func allowResolves() async throws {
        let store = SessionStore()
        store.approvalMatcher = "Bash"

        let pending = Task {
            await store.handle(try! self.event("PreToolUse", payload: [
                "tool_name": "Bash",
                "tool_input": ["command": "npm test"]
            ]))
        }
        let request = try await awaitAnswerableCard(in: store)
        store.allow(request)
        // A second answer must be ignored rather than resuming the continuation
        // twice, which would trap.
        store.deny(request)

        let (reply, reason) = await pending.value
        #expect(reply.decision == .allow)
        #expect(reason == "Approved from Limit Island")
        #expect(store.pending.isEmpty)
    }

    @Test("Waiting requests are answered oldest first")
    func interactionsAreFIFO() async throws {
        let store = SessionStore()
        store.approvalMatcher = "Bash"

        let firstTask = Task {
            await store.handle(try! self.event("PreToolUse", session: "first", payload: [
                "tool_name": "Bash", "tool_input": ["command": "first"]
            ]))
        }
        while store.pending.count < 1 { await Task.yield() }

        let secondTask = Task {
            await store.handle(try! self.event("PreToolUse", session: "second", payload: [
                "tool_name": "Bash", "tool_input": ["command": "second"]
            ]))
        }
        while store.pending.count < 2 { await Task.yield() }

        guard case let .pending(first)? = store.activeInteraction else {
            Issue.record("Expected the oldest pending interaction")
            return
        }
        #expect(first.sessionID == "first")
        try await Task.sleep(for: .milliseconds(Int(PendingRequest.minimumDeliberationTime * 1000) + 80))
        store.allow(first)

        guard case let .pending(second)? = store.activeInteraction else {
            Issue.record("Expected the next pending interaction")
            return
        }
        #expect(second.sessionID == "second")
        store.deny(second)
        _ = await firstTask.value
        _ = await secondTask.value
        #expect(store.activeInteraction == nil)
    }

    @Test("Answering in the terminal drops the card instead of leaving it up")
    func postToolUseClearsTheCard() async throws {
        let store = SessionStore()
        store.approvalMatcher = "Bash"

        let pending = Task {
            await store.handle(try! self.event("PreToolUse", payload: [
                "tool_name": "Bash",
                "tool_input": ["command": "npm test"]
            ]))
        }
        while store.pending.isEmpty { await Task.yield() }

        _ = await store.handle(try event("PostToolUse", payload: ["tool_name": "Bash"]))
        let (reply, _) = await pending.value
        #expect(reply.decision == nil)
        #expect(store.pending.isEmpty)
    }
}

@Suite("Tool descriptions")
struct ToolSummaryTests {
    private func input(_ members: [String: JSONValue]) -> JSONValue { .object(members) }

    @Test("Common tools read as sentences, and paths shorten to their name")
    func activityText() {
        #expect(ToolSummary.activity(tool: "Edit", input: input(["file_path": .string("/a/b/middleware.ts")])) == "Editing middleware.ts")
        #expect(ToolSummary.activity(tool: "Write", input: input(["file_path": .string("/a/b/new.swift")])) == "Writing new.swift")
        #expect(ToolSummary.activity(tool: "Bash", input: input(["command": .string("npm test")])) == "Running npm test")
        #expect(ToolSummary.activity(tool: "TodoWrite", input: nil) == "Updating its plan")
    }

    @Test("An unknown tool falls back to its own name rather than a guess")
    func unknownTool() {
        #expect(ToolSummary.activity(tool: "mcp__weather__forecast", input: nil) == "mcp__weather__forecast")
    }

    @Test("A long command is truncated instead of overflowing the row")
    func truncation() {
        let long = String(repeating: "x", count: 200)
        let summary = ToolSummary.activity(tool: "Bash", input: input(["command": .string(long)]))
        #expect(summary.count < 50)
        #expect(summary.hasSuffix("…"))
    }
}
