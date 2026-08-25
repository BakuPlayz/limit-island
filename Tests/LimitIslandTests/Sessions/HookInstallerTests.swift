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

    @Test("A settings file missing one of our events counts as needing repair")
    func missingEventIsStale() {
        // How `PermissionRequest` went missing for months: it was added to `events`
        // long after the file was written, and a check that only looked at the
        // helper's path called that installation healthy.
        var settings = installed(into: [:])
        var hooks = try! #require(settings["hooks"] as? [String: Any])
        hooks["PermissionRequest"] = nil
        settings["hooks"] = hooks

        #expect(HookInstaller.eventsMissing(from: hooks) == ["PermissionRequest"])
        #expect(HookInstaller.state(of: settings) == .stale)
        #expect(HookInstaller.state(of: installed(into: [:])) == .installed)
        #expect(HookInstaller.state(of: [:]) == .absent)
    }

    @Test("A hook of the user's own does not stand in for one of ours")
    func foreignHookIsNotOurs() {
        let settings: [String: Any] = ["hooks": [
            "PermissionRequest": [["hooks": [["type": "command", "command": "/usr/local/bin/theirs"]]]]
        ]]
        #expect(HookInstaller.eventsMissing(from: settings["hooks"] as! [String: Any])
            .contains("PermissionRequest"))
        #expect(HookInstaller.state(of: settings) == .absent)
    }

    // MARK: - Codex

    /// The same merge `installCodex` performs on `~/.codex/hooks.json`, in memory.
    private func codexInstalled(into hooks: [String: Any]) -> [String: Any] {
        var updated = hooks
        for event in HookInstaller.codexEvents {
            var matchers = (updated[event] as? [[String: Any]]) ?? []
            matchers.append(["hooks": [[
                "type": "command",
                "command": "\"/Applications/LimitIsland.app/Contents/Helpers/limitisland-hook\" \(event) codex",
                "timeout": 540
            ]]])
            updated[event] = matchers
        }
        return updated
    }

    /// Approvals arrive on `PermissionRequest`; questions arrive on `PreToolUse`, and
    /// answering one is only possible while its call is blocked. Losing the second
    /// entry silently returns Codex to being unanswerable.
    @Test("Codex gets both the approval hook and the question hook")
    func codexInstallsBothEvents() throws {
        #expect(HookInstaller.codexEvents.contains("PermissionRequest"))
        #expect(HookInstaller.codexEvents.contains("PreToolUse"))

        let after = codexInstalled(into: [:])
        for event in HookInstaller.codexEvents {
            let matchers = try #require(after[event] as? [[String: Any]])
            let hooks = try #require(matchers.last?["hooks"] as? [[String: Any]])
            let command = try #require(hooks.first?["command"] as? String)
            #expect(command.contains("limitisland-hook"))
            #expect(command.hasSuffix("\(event) codex"))
            // Both block a running CLI, so both need a human-scale timeout.
            #expect(hooks.first?["timeout"] as? Int == 540)
        }
    }

    /// Codex honours a matcher-less entry — that is how the approval hook has always
    /// been installed — and scoping `PreToolUse` would be a guess at matcher syntax
    /// that fails closed. The narrowing happens in the helper instead.
    @Test("Codex entries carry no matcher to get wrong")
    func codexEntriesHaveNoMatcher() throws {
        let after = codexInstalled(into: [:])
        for event in HookInstaller.codexEvents {
            let matchers = try #require(after[event] as? [[String: Any]])
            #expect(matchers.last?["matcher"] == nil)
        }
    }

    @Test("A Codex hook the user already wrote survives ours")
    func codexPreservesForeignHooks() throws {
        let before: [String: Any] = [
            "PreToolUse": [["hooks": [["type": "command", "command": "/usr/local/bin/theirs"]]]]
        ]
        let after = codexInstalled(into: before)
        let matchers = try #require(after["PreToolUse"] as? [[String: Any]])
        #expect(matchers.count == 2)
        let theirs = try #require(matchers.first?["hooks"] as? [[String: Any]])
        #expect(theirs.first?["command"] as? String == "/usr/local/bin/theirs")
    }

    // MARK: - Gemini (Antigravity)

    /// The same merge `installGemini` performs, in memory, so the real
    /// `~/.gemini/config/hooks.json` is never touched by a test run.
    private func geminiInstalled(into hooks: [String: Any]) -> [String: Any] {
        var updated = hooks
        var bundle: [String: Any] = [:]
        for event in HookInstaller.geminiEvents { bundle[event] = HookInstaller.geminiEntry(for: event) }
        updated[HookInstaller.geminiHookName] = bundle
        return updated
    }

    @Test("Antigravity's two entry shapes are used where each belongs")
    func geminiEntryShapes() throws {
        // Tool-scoped events are wrapped in a matcher group; the rest are a flat
        // list of handlers. The wrong shape is accepted and silently ignored, which
        // would look exactly like a hook that never fires.
        let grouped = try #require(HookInstaller.geminiEntry(for: "PreToolUse") as? [[String: Any]])
        #expect(grouped.first?["matcher"] as? String == "*")
        #expect(grouped.first?["hooks"] as? [[String: Any]] != nil)

        let flat = try #require(HookInstaller.geminiEntry(for: "Stop") as? [[String: Any]])
        #expect(flat.first?["matcher"] == nil)
        #expect(flat.first?["hooks"] == nil)
        #expect(flat.first?["type"] as? String == "command")
        #expect((flat.first?["command"] as? String)?.hasSuffix(" Stop gemini") == true)
    }

    @Test("Only the tool call can be answered, so only it waits")
    func geminiBlockingTimeout() throws {
        func timeout(_ event: String, in entry: Any) throws -> Int {
            let entries = try #require(entry as? [[String: Any]])
            let handlers = (entries.first?["hooks"] as? [[String: Any]]) ?? entries
            return try #require(handlers.first?["timeout"] as? Int)
        }
        let blocking = try timeout("PreToolUse", in: HookInstaller.geminiEntry(for: "PreToolUse"))
        let reporting = try timeout("PreInvocation", in: HookInstaller.geminiEntry(for: "PreInvocation"))

        #expect(reporting <= 5)
        #expect(blocking > Int(SessionStore.decisionTimeout.components.seconds))
    }

    @Test("Hook bundles belonging to plugins and people survive ours")
    func geminiPreservesForeignBundles() throws {
        let theirs: [String: Any] = [
            "PostToolUse": [["matcher": "run_command", "hooks": [[
                "type": "command", "command": "./scripts/lint.sh"
            ]]]]
        ]
        let after = geminiInstalled(into: ["lint-checker": theirs])

        #expect(after["lint-checker"] as? [String: Any] != nil)
        #expect(after[HookInstaller.geminiHookName] as? [String: Any] != nil)
        // And removing ours is the removal of exactly one key.
        var removed = after
        removed[HookInstaller.geminiHookName] = nil
        #expect(removed.count == 1)
        #expect(HookInstaller.geminiState(of: removed) == .absent)
    }

    @Test("A bundle missing one of our events counts as needing repair")
    func geminiMissingEventIsStale() throws {
        let installed = geminiInstalled(into: [:])
        #expect(HookInstaller.geminiState(of: installed) == .installed)
        #expect(HookInstaller.geminiState(of: [:]) == .absent)

        var bundle = try #require(installed[HookInstaller.geminiHookName] as? [String: Any])
        bundle["Stop"] = nil
        #expect(HookInstaller.geminiEventsMissing(from: bundle) == ["Stop"])
        #expect(HookInstaller.geminiState(of: [HookInstaller.geminiHookName: bundle]) == .stale)
    }

    @Test("Someone else's hook under our own key is not mistaken for ours")
    func geminiForeignHandlerIsNotOurs() {
        let bundle: [String: Any] = [
            "Stop": [["type": "command", "command": "/usr/local/bin/theirs"]]
        ]
        #expect(HookInstaller.geminiState(of: [HookInstaller.geminiHookName: bundle]) == .absent)
    }

    @Test("Every Antigravity event we ask for is one it actually offers")
    func geminiEventsAreKnown() {
        // Its hook contract has exactly these five; there is no SessionStart or
        // SessionEnd to ask for.
        let known: Set<String> = ["PreToolUse", "PostToolUse", "PreInvocation", "PostInvocation", "Stop"]
        #expect(Set(HookInstaller.geminiEvents) == known)
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
