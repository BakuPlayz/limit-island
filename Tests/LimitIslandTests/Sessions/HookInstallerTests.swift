import Foundation
import Testing
@testable import LimitIsland

/// The installer edits a file the user owns. These tests are about the promises
/// made in Settings: nothing of theirs is lost, and removing takes out only ours.
@Suite("Hook installation")
struct HookInstallerTests {
    /// Applies the same merge the installer performs, against an in-memory
    /// settings dictionary, so the real `~/.claude/settings.json` is never touched
    /// by a test run.
    private func installed(into settings: [String: Any]) -> [String: Any] {
        var updated = settings
        var hooks = updated["hooks"] as? [String: Any] ?? [:]
        for event in HookInstaller.events {
            var matchers = (hooks[event] as? [[String: Any]]) ?? []
            matchers.append(HookInstaller.matcherEntry(for: event))
            hooks[event] = matchers
        }
        updated["hooks"] = hooks
        return updated
    }

    @Test("Every setting that was there before is still there after")
    func preservesUnrelatedKeys() {
        let before: [String: Any] = [
            "model": "opus",
            "theme": "dark-daltonized",
            "effortLevel": "medium",
            "enabledPlugins": ["swift-lsp@claude-plugins-official": true]
        ]
        let after = installed(into: before)

        #expect(after["model"] as? String == "opus")
        #expect(after["theme"] as? String == "dark-daltonized")
        #expect(after["effortLevel"] as? String == "medium")
        #expect((after["enabledPlugins"] as? [String: Bool])?.count == 1)
    }

    @Test("A hook the user already wrote is left alone")
    func preservesForeignHooks() {
        let mine: [String: Any] = [
            "matcher": "Bash",
            "hooks": [["type": "command", "command": "/usr/local/bin/my-audit-log"]]
        ]
        let after = installed(into: ["hooks": ["PreToolUse": [mine]]])
        let entries = after["hooks"] as? [String: Any]
        let preToolUse = entries?["PreToolUse"] as? [[String: Any]]

        #expect(preToolUse?.count == 2)
        let commands = preToolUse?
            .compactMap { $0["hooks"] as? [[String: Any]] }
            .flatMap { $0 }
            .compactMap { $0["command"] as? String }
        #expect(commands?.contains("/usr/local/bin/my-audit-log") == true)
    }

    @Test("Only the tool-scoped events get a matcher")
    func matcherPlacement() {
        #expect(HookInstaller.matcherEntry(for: "PreToolUse")["matcher"] as? String == "*")
        #expect(HookInstaller.matcherEntry(for: "PostToolUse")["matcher"] as? String == "*")
        #expect(HookInstaller.matcherEntry(for: "SessionStart")["matcher"] == nil)
        #expect(HookInstaller.matcherEntry(for: "Stop")["matcher"] == nil)
    }

    @Test("The blocking event is given far more time than the reporting ones")
    func blockingTimeoutIsGenerous() throws {
        func timeout(_ event: String) throws -> Int {
            let hooks = try #require(HookInstaller.matcherEntry(for: event)["hooks"] as? [[String: Any]])
            return try #require(hooks.first?["timeout"] as? Int)
        }
        let blocking = try timeout("PreToolUse")
        let reporting = try timeout("Stop")

        #expect(reporting <= 5, "a reporting hook must not delay the CLI")
        // The app has to give up first, or the CLI would kill the hook while the
        // person was still reading the card.
        #expect(blocking > Int(SessionStore.decisionTimeout.components.seconds))
    }

    @Test("The command names the helper so uninstall can find it again")
    func commandIsIdentifiable() throws {
        let hooks = try #require(HookInstaller.matcherEntry(for: "Stop")["hooks"] as? [[String: Any]])
        let command = try #require(hooks.first?["command"] as? String)
        #expect(command.contains("limitisland-hook"))
        // Quoted, because an app installed under "Application Support" or any
        // other path with a space would otherwise be split into two arguments.
        #expect(command.hasPrefix("\""))
        #expect(command.hasSuffix(" Stop claude"))
    }

    @Test("Every event we ask for is one the CLI actually emits")
    func eventsAreKnown() {
        let known: Set<String> = [
            "SessionStart", "SessionEnd", "UserPromptSubmit",
            "PreToolUse", "PermissionRequest", "PostToolUse", "Notification", "Stop", "SubagentStop"
        ]
        #expect(Set(HookInstaller.events).isSubset(of: known))
    }
}
