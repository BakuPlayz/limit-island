import Foundation
import Testing
@testable import LimitIsland

/// The helper builds its frames with `JSONSerialization` and the app decodes them
/// with `Codable`, so nothing but these tests keeps the two in step.
@Suite("Hook wire format")
struct HookProtocolTests {
    private func decode(_ json: String) throws -> HookEvent {
        try JSONDecoder().decode(HookEvent.self, from: Data(json.utf8))
    }

    @Test("A frame the helper would send decodes into an event")
    func decodesHelperFrame() throws {
        let event = try decode("""
        {
          "event": "PreToolUse",
          "cli": "claude",
          "payload": {
            "session_id": "abc-123",
            "cwd": "/Users/me/Code/thing",
            "tool_name": "Edit",
            "tool_input": {"file_path": "/Users/me/Code/thing/src/auth.ts", "old_string": "a", "new_string": "b"}
          },
          "env": {"TERM_PROGRAM": "iTerm.app", "ITERM_SESSION_ID": "w0t1p0:UUID"},
          "pids": [412, 411, 380],
          "tty": "/dev/ttys004",
          "sentAt": 1786276800.5
        }
        """)

        #expect(event.sessionID == "abc-123")
        #expect(event.toolName == "Edit")
        #expect(event.provider == .claude)
        #expect(event.workingDirectory == "/Users/me/Code/thing")
        #expect(event.toolInput?.string("old_string") == "a")

        let terminal = TerminalRef(event: event)
        #expect(terminal.displayName == "iTerm")
        #expect(terminal.iTermSessionID == "w0t1p0:UUID")
        #expect(terminal.tty == "/dev/ttys004")
        #expect(terminal.workingDirectory == "/Users/me/Code/thing")
        #expect(terminal.pids == [412, 411, 380])
    }

    @Test("A terminal destination has a stable namespaced identity")
    func terminalDestinationIdentity() {
        let destination = TerminalDestination(
            kind: .ghostty, stableID: "surface-42", terminalName: "Ghostty",
            title: "agent", workingDirectory: "/Users/me/Code/thing"
        )
        #expect(destination.id == "ghostty:surface-42")
    }

    @Test("A numeric session id still reads as one")
    func tolerantIdentifiers() throws {
        // Claude's organizations endpoint once broke exactly this way: a field
        // declared String that arrived as a number failed the whole payload.
        let event = try decode(#"{"event":"Stop","cli":"claude","payload":{"session_id":42},"env":{},"pids":[],"tty":"","sentAt":0}"#)
        #expect(event.sessionID == "42")
    }

    @Test("Codex notify thread IDs bind to the same session identity")
    func codexThreadIdentifier() throws {
        let event = try decode(#"{"event":"notify","cli":"codex","payload":{"thread_id":"019ff192-4b71-7521-bce1-12a7b0919ceb"},"env":{},"pids":[],"tty":"","sentAt":0}"#)
        #expect(event.sessionID == "019ff192-4b71-7521-bce1-12a7b0919ceb")
    }

    @Test("An Antigravity frame decodes despite naming everything differently")
    func decodesGeminiFrame() throws {
        // Antigravity's payloads are protojson: camelCase throughout, a workspace
        // rather than a directory, and the tool call nested under one key.
        let event = try decode("""
        {
          "event": "PreToolUse",
          "cli": "gemini",
          "payload": {
            "conversationId": "6d62b653-00bd-4359-a52f-5908c59d14c9",
            "workspacePaths": ["/Users/me/Code/thing"],
            "transcriptPath": "/Users/me/Code/thing/.gemini/antigravity-cli/transcript.jsonl",
            "modelName": "gemini-3.6-flash-medium",
            "stepIdx": 19,
            "toolCall": {"name": "run_command", "args": {"CommandLine": "npm test"}}
          },
          "env": {"TERM_PROGRAM": "Apple_Terminal"},
          "pids": [901, 900],
          "tty": "/dev/ttys009",
          "sentAt": 1786276800.5
        }
        """)

        #expect(event.provider == .gemini)
        #expect(event.sessionID == "6d62b653-00bd-4359-a52f-5908c59d14c9")
        #expect(event.workingDirectory == "/Users/me/Code/thing")
        #expect(event.toolName == "run_command")
        #expect(event.toolInput?.string("CommandLine") == "npm test")
        #expect(event.model == "gemini-3.6-flash-medium")
        #expect(event.transcriptPath?.hasSuffix("transcript.jsonl") == true)
        // It reports no permission mode at all, and the safe reading of that is to ask.
        #expect(event.permissionMode == .standard)
        #expect(event.reportedPermissionMode == nil)
    }

    @Test("A tool's arguments are found under either spelling Antigravity uses")
    func geminiArgumentAliases() throws {
        let args = try decode(#"{"event":"PreToolUse","cli":"gemini","payload":{"conversationId":"s","toolCall":{"name":"edit_file","args":{"TargetFile":"/a/b.swift"}}},"env":{},"pids":[],"tty":"","sentAt":0}"#)
        #expect(args.toolInput?.string("TargetFile") == "/a/b.swift")

        let arguments = try decode(#"{"event":"PreToolUse","cli":"gemini","payload":{"conversationId":"s","toolCall":{"name":"edit_file","arguments":{"TargetFile":"/a/b.swift"}}},"env":{},"pids":[],"tty":"","sentAt":0}"#)
        #expect(arguments.toolInput?.string("TargetFile") == "/a/b.swift")
    }

    @Test("Antigravity decisions use its own flat shape")
    func geminiDecisionShape() throws {
        let event = try decode(#"{"event":"PreToolUse","cli":"gemini","payload":{"conversationId":"s"},"env":{},"pids":[],"tty":"","sentAt":0}"#)
        let text = HookReply(decision: .allow).serialised(for: event, reason: "Approved from Limit Island")
        let root = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(root["decision"] as? String == "allow")
        #expect(root["reason"] as? String == "Approved from Limit Island")
        // The Claude shape must not leak into it: Antigravity reads only these keys.
        #expect(root["hookSpecificOutput"] == nil)

        let denial = HookReply(decision: .deny).serialised(for: event, reason: nil)
        let denialRoot = try #require(try JSONSerialization.jsonObject(with: Data(denial.utf8)) as? [String: Any])
        #expect(denialRoot["decision"] as? String == "deny")
        #expect(denialRoot["reason"] == nil)

        // Silence still has to be silence, or every tool call would be allowed.
        #expect(HookReply.noOpinion.serialised(for: event, reason: nil) == "{}")
    }

    @Test("An unknown CLI is attributed rather than dropped")
    func unknownCLI() throws {
        let event = try decode(#"{"event":"Stop","cli":"codex","payload":{},"env":{},"pids":[],"tty":"","sentAt":0}"#)
        #expect(event.provider == .openAI)
    }

    @Test("tmux's socket is taken from $TMUX without its pid and session fields")
    func tmuxSocketParsing() throws {
        let event = try decode("""
        {"event":"Stop","cli":"claude","payload":{"session_id":"s"},
         "env":{"TMUX":"/private/tmp/tmux-501/default,9182,0","TMUX_PANE":"%3"},
         "pids":[],"tty":"","sentAt":0}
        """)
        let terminal = TerminalRef(event: event)
        #expect(terminal.tmuxSocket == "/private/tmp/tmux-501/default")
        #expect(terminal.tmuxPane == "%3")
        // A session inside tmux is labelled by tmux, not by the host terminal.
        #expect(terminal.displayName == "tmux")
    }

    @Test("No opinion serialises to an object the CLI treats as silence")
    func noOpinionIsEmpty() {
        #expect(HookReply.noOpinion.serialised(reason: nil) == "{}")
        #expect(HookReply.noOpinion.serialised(reason: "ignored") == "{}")
    }

    @Test("A decision serialises into Claude Code's PreToolUse shape")
    func decisionShape() throws {
        let text = HookReply(decision: .allow).serialised(reason: "Approved from Limit Island")
        let root = try #require(
            try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        )
        let specific = try #require(root["hookSpecificOutput"] as? [String: Any])
        #expect(specific["hookEventName"] as? String == "PreToolUse")
        #expect(specific["permissionDecision"] as? String == "allow")
        #expect(specific["permissionDecisionReason"] as? String == "Approved from Limit Island")

        let denial = HookReply(decision: .deny).serialised(reason: nil)
        let denialRoot = try #require(
            try JSONSerialization.jsonObject(with: Data(denial.utf8)) as? [String: Any]
        )
        let denialSpecific = try #require(denialRoot["hookSpecificOutput"] as? [String: Any])
        #expect(denialSpecific["permissionDecision"] as? String == "deny")
        #expect(denialSpecific["permissionDecisionReason"] == nil)
    }

    @Test("Codex permission decisions use its PermissionRequest shape")
    func codexPermissionShape() throws {
        let event = try decode(#"{"event":"PermissionRequest","cli":"codex","payload":{"thread_id":"s","tool_name":"exec"},"env":{},"pids":[],"tty":"","sentAt":0}"#)
        let text = HookReply(decision: .allow).serialised(for: event, reason: "Approved")
        let root = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let specific = try #require(root["hookSpecificOutput"] as? [String: Any])
        let decision = try #require(specific["decision"] as? [String: Any])
        #expect(specific["hookEventName"] as? String == "PermissionRequest")
        #expect(decision["behavior"] as? String == "allow")
    }

    /// Verified against a live Codex 0.147 session: this exact JSON on the hook's
    /// stdout blocked `request_user_input`, put the reason in front of the model, and
    /// the model continued from the answers without asking again.
    @Test("A Codex question is answered in its PreToolUse shape, reason and all")
    func codexQuestionShape() throws {
        let event = try decode(#"{"event":"PreToolUse","cli":"codex","payload":{"session_id":"s","tool_name":"request_user_input"},"env":{},"pids":[],"tty":"","sentAt":0}"#)
        let text = HookReply(decision: .deny).serialised(for: event, reason: "scope: Entire app")
        let root = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let specific = try #require(root["hookSpecificOutput"] as? [String: Any])
        #expect(specific["hookEventName"] as? String == "PreToolUse")
        // Denying is what stops Codex drawing its own picker; the reason is the only
        // channel a hook has to the model, so it must survive serialisation.
        #expect(specific["permissionDecision"] as? String == "deny")
        #expect(specific["permissionDecisionReason"] as? String == "scope: Entire app")
    }

    @Test("Auto is its own mode, not a synonym for bypass")
    func autoModeIsDistinct() {
        // Kept apart because a switch into auto can be refused by the CLI's own gate,
        // and a mode folded into another cannot be checked afterwards.
        #expect(PermissionMode("auto") == .auto)
        #expect(PermissionMode("bypassPermissions") == .bypass)
        // It asks about nothing, exactly as it did when it parsed to bypass — naming
        // it must not change what the notch interrupts.
        #expect(PermissionMode.auto.asksAbout("Edit") == false)
        #expect(PermissionMode.auto.asksAbout("Bash") == false)
        #expect(PermissionMode.auto.isAutomatic)
    }

    @Test("An unrecognised mode still asks")
    func unknownModeAsks() {
        // The safe direction: a mode we do not know must never read as blanket
        // permission.
        #expect(PermissionMode("some-future-mode") == .standard)
        #expect(PermissionMode(nil) == .standard)
        #expect(PermissionMode("some-future-mode").asksAbout("Bash"))
    }

    @Test("A mode switch rides on PermissionRequest, the only event that can carry one")
    func modeSwitchShape() throws {
        let event = try decode(#"{"event":"PermissionRequest","cli":"claude","payload":{"session_id":"s","tool_name":"Edit"},"env":{},"pids":[],"tty":"","sentAt":0}"#)
        let reply = HookReply(decision: .allow, updatedPermissionMode: "acceptEdits")
        let root = try #require(try JSONSerialization.jsonObject(
            with: Data(reply.serialised(for: event, reason: "Auto-approved").utf8)
        ) as? [String: Any])
        let decision = try #require(
            (root["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any]
        )
        #expect(decision["behavior"] as? String == "allow")
        // `message` belongs to the deny arm of the CLI's schema; the allow arm takes
        // only `updatedInput` and `updatedPermissions`.
        #expect(decision["message"] == nil)

        let permissions = try #require(decision["updatedPermissions"] as? [[String: Any]])
        #expect(permissions.count == 1)
        #expect(permissions[0]["type"] as? String == "setMode")
        #expect(permissions[0]["mode"] as? String == "acceptEdits")
        #expect(permissions[0]["destination"] as? String == "session")
    }

    @Test("PreToolUse cannot carry a mode, so it must not pretend to")
    func preToolUseDropsTheMode() throws {
        // The CLI's PreToolUse schema is permissionDecision / permissionDecisionReason
        // / updatedInput / additionalContext. Anything else is silently dropped, which
        // is exactly how "Auto approve" used to look like it worked and never did.
        let reply = HookReply(decision: .allow, updatedPermissionMode: "acceptEdits")
        let root = try #require(try JSONSerialization.jsonObject(
            with: Data(reply.serialised(reason: nil).utf8)
        ) as? [String: Any])
        let specific = try #require(root["hookSpecificOutput"] as? [String: Any])
        #expect(specific["hookEventName"] as? String == "PreToolUse")
        #expect(specific["updatedPermissions"] == nil)
        #expect(specific["updatedPermissionMode"] == nil)
    }

    @Test("A denial still explains itself")
    func denialKeepsItsMessage() throws {
        let event = try decode(#"{"event":"PermissionRequest","cli":"claude","payload":{"session_id":"s","tool_name":"Edit"},"env":{},"pids":[],"tty":"","sentAt":0}"#)
        let text = HookReply(decision: .deny).serialised(for: event, reason: "Denied from Limit Island")
        let root = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let decision = try #require(
            (root["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any]
        )
        #expect(decision["behavior"] as? String == "deny")
        #expect(decision["message"] as? String == "Denied from Limit Island")
    }

    @Test("Question answers preserve questions and add updated answers")
    func questionAnswerShape() throws {
        let input: JSONValue = .object([
            "questions": .array([.object([
                "question": .string("Which target?"), "header": .string("Target"),
                "options": .array([.object(["label": .string("Production")])])
            ])]),
            "answers": .object(["Which target?": .string("Production")])
        ])
        let text = HookReply(decision: .allow, updatedInput: input).serialised(reason: nil)
        let root = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let specific = try #require(root["hookSpecificOutput"] as? [String: Any])
        let updated = try #require(specific["updatedInput"] as? [String: Any])
        let answers = try #require(updated["answers"] as? [String: Any])
        #expect(answers["Which target?"] as? String == "Production")
    }

    @Test("Permission modes are read from the payload, and an unknown one asks")
    func permissionModes() throws {
        func mode(_ raw: String) throws -> PermissionMode {
            try decode("""
            {"event":"PreToolUse","cli":"claude","payload":{"session_id":"s","permission_mode":"\(raw)"},
             "env":{},"pids":[],"tty":"","sentAt":0}
            """).permissionMode
        }
        #expect(try mode("default") == .standard)
        #expect(try mode("acceptEdits") == .acceptEdits)
        #expect(try mode("bypassPermissions") == .bypass)
        #expect(try mode("plan") == .plan)
        // A mode we have never heard of must fall back to asking. Reading an
        // unrecognised string as blanket permission is the one unsafe direction.
        #expect(try mode("someFutureMode") == .standard)

        let absent = try decode(#"{"event":"PreToolUse","cli":"claude","payload":{"session_id":"s"},"env":{},"pids":[],"tty":"","sentAt":0}"#)
        #expect(absent.permissionMode == .standard)
    }

    @Test("Codex auto approval policy is a bypass mode")
    func codexAutoPolicy() throws {
        let event = try decode(#"{"event":"PermissionRequest","cli":"codex","payload":{"thread_id":"s","tool_name":"exec","approval_policy":"never"},"env":{},"pids":[],"tty":"","sentAt":0}"#)
        #expect(event.permissionMode == .bypass)
    }

    @Test("Claude notification types are normalized")
    func notificationTypes() throws {
        func type(_ raw: String) throws -> NotificationType {
            try decode("""
            {"event":"Notification","cli":"claude","payload":{"session_id":"s","notification_type":"\(raw)"},
             "env":{},"pids":[],"tty":"","sentAt":0}
            """).notificationType
        }
        #expect(try type("permission_prompt") == .permissionPrompt)
        #expect(try type("idle_prompt") == .idlePrompt)
        #expect(try type("auth_success") == .passive)
        #expect(try type("future_type") == .unknown)
    }

    @Test("Only PreToolUse blocks, and both sides agree on that")
    func blockingEventsAgree() throws {
        // The helper decides whether to wait for a reply; the server decides whether
        // to park a thread producing one. If they disagree, either the CLI hangs
        // until its hook times out or a decision is written to a socket nobody is
        // reading. The helper's list lives in Sources/LimitIslandHook/main.swift.
        #expect(HookServer.blockingEvents == ["PreToolUse", "PermissionRequest"])

        let helper = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // …/Tests/LimitIslandTests/Sessions
            .deletingLastPathComponent()   // …/Tests/LimitIslandTests
            .deletingLastPathComponent()   // …/Tests
            .deletingLastPathComponent()   // repository root
            .appendingPathComponent("Sources/LimitIslandHook/main.swift")
        let source = try String(contentsOf: helper, encoding: .utf8)
        for event in HookServer.blockingEvents {
            #expect(source.contains("\"\(event)\""), "helper does not wait for \(event)")
        }
    }

    @Test("The socket path fits inside AF_UNIX's limit")
    func socketPathFits() {
        // sockaddr_un.sun_path is 104 bytes. Exceeding it is a silent bind failure,
        // which would look exactly like the app not running.
        #expect(HookServer.socketURL.path.utf8.count < 104)
    }
}
