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

    @Test("Only PreToolUse blocks, and both sides agree on that")
    func blockingEventsAgree() throws {
        // The helper decides whether to wait for a reply; the server decides whether
        // to park a thread producing one. If they disagree, either the CLI hangs
        // until its hook times out or a decision is written to a socket nobody is
        // reading. The helper's list lives in Sources/LimitIslandHook/main.swift.
        #expect(HookServer.blockingEvents == ["PreToolUse"])

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
