import AppKit
import SwiftUI

@main
struct LimitIslandApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("Limit Island", systemImage: "gauge.with.dots.needle.67percent") {
            MenuBarView(state: appDelegate.quota)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView(state: appDelegate.quota, sessions: appDelegate.sessions)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let quota = QuotaStore()
    let sessions = SessionStore()
    let codexReset = CodexResetStore()
    let autoContinue = AutoContinueStore()
    private var islandController: IslandWindowController?
    private var hookServer: HookServer?
    private var codexWatcher: CodexSessionWatcher?
    private var wakeObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Keep LimitIsland as a menu-bar utility, not a Dock application.
        NSApp.setActivationPolicy(.accessory)

        let controller = IslandWindowController(
            quota: quota, sessions: sessions, codexReset: codexReset, autoContinue: autoContinue
        )
        controller.show()
        islandController = controller

        startHookServer()
        HookInstaller.installClaudeAutomaticallyIfAvailable()
        HookInstaller.installGeminiAutomaticallyIfAvailable()

        // Codex reaches the panel by transcript rather than by hook — see
        // `CodexSessionWatcher` for why it has to.
        let watcher = CodexSessionWatcher { [sessions] update in
            sessions.apply(update)
            // A rollout proves Codex is present. Its notify hook only affects
            // later turns, while the transcript keeps this one live immediately.
            HookInstaller.installCodexAutomatically()
        }
        watcher.start()
        codexWatcher = watcher

        // Claude Code has no equivalent watcher — it speaks only through hooks, so an
        // agent already at work when we launched would stay invisible until its next
        // tool call. Its transcripts say who is running right now; read them once.
        // The same is true of Antigravity, and more so: its hooks fire only when a
        // turn runs, so a session sitting at its prompt says nothing at all.
        Task { [sessions] in
            let adopted = await Task.detached {
                ClaudeTranscriptAdopter.discover() + GeminiSessionAdopter.discover()
            }.value
            sessions.adopt(adopted)
        }

        quota.start()
        sessions.start()
        codexReset.start()
        autoContinue.start { [sessions] plan in
            await Self.resume(plan, in: sessions)
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.quota.refreshAfterWake()
                self?.codexReset.refreshAfterWake()
                self?.autoContinue.refreshAfterWake()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Order matters: releasing blocked hooks before tearing the socket down
        // means an agent waiting on a decision continues with its own prompt
        // rather than sitting on a socket that is about to disappear.
        sessions.stop()
        hookServer?.stop()
        codexWatcher?.stop()
        quota.stop()
        codexReset.stop()
        autoContinue.stop()
        islandController?.stop()
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
    }

    /// Puts a scheduled prompt back into its Claude session.
    ///
    /// The session is found by id first and by terminal identity second: a five-hour
    /// wait outlives the app, and a session rebuilt from its transcript at launch
    /// comes back under a new id while the pane it lives in has not moved. If
    /// neither matches, nothing is typed — the alternative is a sentence appearing
    /// in whatever now owns that terminal.
    private static func resume(_ plan: ScheduledContinue, in sessions: SessionStore) async -> AutoContinueStore.Outcome {
        let match = sessions.session(id: plan.sessionID) ?? sessions.sessions.first {
            guard let identity = $0.terminal?.stableIdentity else { return false }
            return identity == plan.terminal.stableIdentity
        }
        guard let session = match else { return .sessionGone }
        guard await TerminalJumper.sendPrompt(plan.message, in: session) else { return .sendFailed }
        return .sent(project: session.project ?? plan.project)
    }

    private func startHookServer() {
        let server = HookServer { [sessions] event in
            await sessions.handle(event)
        }
        do {
            try server.start()
            hookServer = server
        } catch {
            // The app is still useful without it — quota keeps working, sessions
            // do not appear — so this reports rather than fails to launch.
            Log.hooks.error("could not start the hook server: \(String(describing: error), privacy: .public)")
        }
    }
}
