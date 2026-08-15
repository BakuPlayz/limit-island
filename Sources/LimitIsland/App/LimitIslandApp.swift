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
    private var islandController: IslandWindowController?
    private var hookServer: HookServer?
    private var codexWatcher: CodexSessionWatcher?
    private var wakeObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Keep LimitIsland as a menu-bar utility, not a Dock application.
        NSApp.setActivationPolicy(.accessory)

        let controller = IslandWindowController(
            quota: quota, sessions: sessions, codexReset: codexReset
        )
        controller.show()
        islandController = controller

        startHookServer()
        HookInstaller.installClaudeAutomaticallyIfAvailable()

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

        quota.start()
        sessions.start()
        codexReset.start()
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.quota.refreshAfterWake()
                self?.codexReset.refreshAfterWake()
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
        islandController?.stop()
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
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
