import AppKit
import Combine
import SwiftUI

/// A panel that will not take key or main status under any circumstances.
///
/// `NSPanel` differs from `NSWindow` here: a borderless `NSWindow` refuses key
/// status, but a borderless `NSPanel` accepts it — which is what makes
/// Spotlight-style panels possible, and what let SwiftUI put keyboard focus on the
/// first control inside the permission card. A focused control can be fired by
/// Return or Space, so a permission request could be answered by a keystroke aimed
/// at something else entirely.
private final class NeverKeyPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Places and sizes the notch window, and decides which presentation it shows.
///
/// > **The rule this class is built around: never mutate the window's geometry or
/// > its view hierarchy synchronously from inside a SwiftUI callback.**
///
/// An earlier version broke it and crashed on a timer. `.onHover` ran during
/// AppKit's layout pass and called through to `panel.contentView = NSHostingView(…)`,
/// which removed the very view being laid out; AppKit threw rather than schedule
/// constraint updates for a window already mid-layout. Two things follow, and both
/// are load-bearing:
///
/// * the hosting view is built **once**, in `init`, and never replaced — everything
///   that used to justify rebuilding it now lives in `IslandPresenter`, which
///   SwiftUI observes; and
/// * callbacks that originate in SwiftUI — `toggle`, and the jump handler — never
///   touch the window inline. They record intent and let a `Task` reach `position()`
///   on a later turn, once AppKit has finished laying out.
///
/// The panel is non-activating and, since a card once answered itself, explicitly
/// never key. That is what lets someone answer a permission request without their
/// editor losing focus. Nothing here may call `makeKeyAndOrderFront`; see
/// `handleKey` for how shortcuts reach a window that is never key.
@MainActor
final class IslandWindowController: NSObject {
    private let quota: QuotaStore
    private let sessions: SessionStore
    private let presenter = IslandPresenter()
    private let panel = IslandWindowController.makePanel()
    private var cancellables = Set<AnyCancellable>()
    private var isVisible = false

    /// Whether the person has opened the panel. Hover used to do this, which
    /// fought the hardware: the pointer's path to the strip runs through the camera
    /// housing, which cannot be hovered, so opening it was a matter of luck.
    private var isOpen = false
    private var keyMonitor: Any?
    /// Installed only while the panel is open, so a click anywhere else closes it.
    private var outsideClickMonitor: Any?

    init(quota: QuotaStore, sessions: SessionStore) {
        self.quota = quota
        self.sessions = sessions
        super.init()

        presenter.refreshHookState()

        // Built once. The closures capture the controller weakly and are the only
        // way SwiftUI talks back to it.
        panel.contentView = NSHostingView(rootView: IslandContent(
            quota: quota,
            sessions: sessions,
            presenter: presenter,
            onToggle: { [weak self] in self?.toggle() },
            onJump: { [weak self] session in
                self?.handleJump(session)
            }
        ))

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in self?.position() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.presenter.refreshHookState() }
            .store(in: &cancellables)
        quota.$meters
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.position() }
            .store(in: &cancellables)
        quota.$usages
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.position() }
            .store(in: &cancellables)
        quota.$leftPinnedMeterID
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.position() }
            .store(in: &cancellables)
        quota.$rightPinnedMeterID
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.position() }
            .store(in: &cancellables)
        observeSessions()
        installKeyMonitor()
    }

    private func handleJump(_ session: AgentSession) {
        switch TerminalJumper.jump(to: session) {
        case .jumped:
            presenter.jumpSheet = nil
            setOpen(false)
        case let .choose(destinations):
            presenter.jumpSheet = .chooser(sessionID: session.id, destinations: destinations)
            setOpen(true)
        case let .automationPermission(terminal):
            presenter.jumpSheet = .automation(sessionID: session.id, terminal: terminal)
            setOpen(true)
        case let .setupRequired(terminal):
            presenter.jumpSheet = .setup(sessionID: session.id, terminal: terminal)
            setOpen(true)
        case .applicationFallback:
            presenter.jumpSheet = nil
            setOpen(false)
        case .stale:
            // Navigation failure is not session lifecycle. Keep the idle row even
            // when neither a tab nor an application can currently be resolved.
            presenter.jumpSheet = .notice("The terminal could not be opened, but this agent remains listed.")
            setOpen(true)
        }
    }

    func show() {
        position()
    }

    /// Called on termination. The key monitor is a process-wide registration, so it
    /// is given up explicitly rather than left to deallocation.
    func stop() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        outsideClickMonitor = nil
    }

    // MARK: - Observation

    /// `SessionStore` is `@Observable`, so there is no publisher to sink. This
    /// re-arms itself after every change, which is the documented way to keep
    /// watching a set of properties from outside SwiftUI.
    ///
    /// `tick` is deliberately **not** observed. It changes once a second to keep
    /// elapsed times fresh, SwiftUI redraws the rows for it on its own, and nothing
    /// about the window's frame depends on it.
    private func observeSessions() {
        withObservationTracking {
            _ = sessions.sessions.count
            _ = sessions.pending.count
            _ = presenter.jumpSheet
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.position()
                self?.observeSessions()
            }
        }
    }

    // MARK: - Opening and closing

    /// Called from the strip's tap gesture. Like every SwiftUI callback here it
    /// records intent and lets a `Task` reach the window on a later turn — see the
    /// note on the class for why touching geometry inline was a crash.
    private func toggle() {
        setOpen(!isOpen)
    }

    private func setOpen(_ open: Bool) {
        guard open != isOpen else { return }
        // A card is a question that has to be answered. Clicking away must not
        // dismiss it — only answering it, or its own timeout, takes it off screen.
        if !open, !sessions.pending.isEmpty { return }
        isOpen = open
        updateOutsideClickMonitor()
        Task { @MainActor [weak self] in self?.position() }
    }

    /// Closes the panel when a click lands anywhere outside it. Only installed while
    /// the panel is open: a permanent global mouse monitor would be watching every
    /// click the person makes all day for no reason.
    private func updateOutsideClickMonitor() {
        if isOpen, outsideClickMonitor == nil {
            outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown]
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.setOpen(false) }
            }
        } else if !isOpen, let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
    }

    // MARK: - Layout

    private func position() {
        guard let screen = preferredScreen else { return }

        // Open because the person asked, or because an agent is waiting on them.
        // The second half is the "it should still open if it needs input" rule: a
        // question surfaces itself rather than waiting to be discovered.
        let wantsExpansion = isOpen || !sessions.pending.isEmpty || sessions.isWaitingOnUser

        guard let leftArea = screen.auxiliaryTopLeftArea,
              let rightArea = screen.auxiliaryTopRightArea else {
            // No camera housing on this display. Earlier builds hid outright here,
            // which retired the app for anyone working on an external monitor.
            presenter.set(\.notchWidth, to: 0)
            presenter.set(\.notchHeight, to: NotchLayout.minimumHeaderHeight)
            present(.floatingBar, frame: floatingFrame(on: screen, expanded: wantsExpansion))
            return
        }

        let notchHeight = max(1, min(leftArea.height, rightArea.height)) + 1
        presenter.set(\.notchWidth, to: max(0, rightArea.minX - leftArea.maxX))
        presenter.set(\.notchHeight, to: notchHeight)

        measureSides(leftArea: leftArea, rightArea: rightArea)

        if wantsExpansion {
            let height = presenter.headerHeight + NotchLayout.panelHeight(
                sessions: contentRowCount,
                cards: sessions.pending.count,
                headerHeight: presenter.headerHeight
            )
            // Reuse the closed strip's exact horizontal frame. Expansion is a
            // vertical reveal below the notch, never a sideways jump to a second
            // fixed panel width.
            let width = stablePanelWidth
            let hasPinnedStrip = presenter.leftWidth > 0 || presenter.rightWidth > 0
            let centre = (leftArea.maxX + rightArea.minX) / 2
            present(.expanded, frame: NSRect(
                x: hasPinnedStrip ? leftArea.maxX - presenter.leftWidth : centre - width / 2,
                y: screen.frame.maxY - height,
                width: width,
                height: height
            ))
            return
        }

        guard presenter.leftWidth > 0 || presenter.rightWidth > 0 else {
            // Nothing to say: no accounts and no sessions. Hide rather than paint a
            // black bar over the notch for no reason.
            hide()
            return
        }

        // Logged because "is anything drawn under the notch?" is otherwise only
        // answerable by squinting at the screen. The invariant is that each side
        // fits its aux area; if one is ever clamped, that shows up here first.
        Log.window.debug("""
            strip: left \(self.presenter.leftWidth, format: .fixed(precision: 0))/\
            \(leftArea.width, format: .fixed(precision: 0)) \
            notch \(self.presenter.notchWidth, format: .fixed(precision: 0)) \
            right \(self.presenter.rightWidth, format: .fixed(precision: 0))/\
            \(rightArea.width, format: .fixed(precision: 0))
            """)

        present(.strip, frame: NSRect(
            x: leftArea.maxX - presenter.leftWidth,
            y: leftArea.minY - 1,
            width: presenter.leftWidth + presenter.notchWidth + presenter.rightWidth,
            height: notchHeight
        ))
    }

    /// Gives both sides the same permanent footprint. Pinning, unpinning, and
    /// quota refreshes must never change the notch bar's horizontal geometry.
    private func measureSides(leftArea: CGRect, rightArea: CGRect) {
        let width = min(NotchLayout.pinnedSlotWidth, leftArea.width, rightArea.width)
        presenter.set(\.leftWidth, to: width)
        presenter.set(\.rightWidth, to: width)
    }

    /// Closed and expanded states always share this width, even when no account is
    /// pinned yet, so opening a panel never moves its left or right edges.
    private var stablePanelWidth: CGFloat {
        presenter.leftWidth + presenter.notchWidth + presenter.rightWidth
    }

    private func floatingFrame(on screen: NSScreen, expanded: Bool) -> NSRect {
        let height = expanded
            ? presenter.headerHeight + NotchLayout.panelHeight(
                sessions: contentRowCount,
                cards: sessions.pending.count,
                headerHeight: presenter.headerHeight
              )
            : presenter.headerHeight + 8
        return NSRect(
            x: screen.frame.midX - NotchLayout.panelWidth / 2,
            y: screen.visibleFrame.maxY - height - 6,
            width: NotchLayout.panelWidth,
            height: height
        )
    }

    private var contentRowCount: Int {
        switch presenter.jumpSheet {
        case let .chooser(_, destinations): max(2, destinations.count + 1)
        case .automation, .setup, .notice: 2
        case nil: sessions.sessions.count
        }
    }

    /// Sets the presentation and the frame. Never builds a view: the hosting view
    /// from `init` observes `presenter` and re-renders itself.
    private func present(_ presentation: IslandPresentation, frame: NSRect) {
        presenter.set(\.presentation, to: presentation)
        // `position()` runs on every session change, and most of those do not move
        // the window at all. Setting an unchanged frame still forces a display pass.
        if panel.frame != frame {
            panel.setFrame(frame, display: true)
        }
        if !isVisible {
            panel.orderFrontRegardless()
            isVisible = true
        }
    }

    private func hide() {
        guard isVisible else { return }
        panel.orderOut(nil)
        isVisible = false
    }

    // MARK: - Keyboard

    /// The panel never becomes key, so SwiftUI's `.keyboardShortcut` never fires.
    /// A global monitor sees the keystroke wherever the person is actually typing,
    /// which is the point: answering without leaving the editor.
    ///
    /// It is deliberately **not** bound to ⌘Y and ⌘N. A global monitor fires for
    /// every application, and those two are already taken: ⌘Y is Redo in a number
    /// of apps and ⌘N is New almost everywhere. Hitting either while a card
    /// happened to be waiting would silently approve or refuse a permission request
    /// the person never looked at — which is exactly the failure this feature must
    /// not have. Adding Control makes the chord one nothing else claims.
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            Task { @MainActor [weak self] in self?.handleKey(event) }
        }
    }

    private func handleKey(_ event: NSEvent) {
        // Only while a card is up. A monitor that acted at any other time would be
        // a keylogger's worth of surprise.
        guard let request = sessions.pending.first else { return }
        let required: NSEvent.ModifierFlags = [.command, .control]
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.isSuperset(of: required), !flags.contains(.option) else { return }

        switch event.charactersIgnoringModifiers?.lowercased() {
        case "y":
            Log.hooks.debug("shortcut: allow")
            sessions.allow(request)
        case "n":
            Log.hooks.debug("shortcut: deny")
            sessions.deny(request)
        default:
            break
        }
    }

    // MARK: - Window

    private static func makePanel() -> NSPanel {
        let panel = NeverKeyPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false
        return panel
    }

    /// The attached display with the deepest safe area — the notched one, if there
    /// is one. `NSScreen.screens` is empty in clamshell with no external display,
    /// where `NSScreen.main` is nil too, so this stays optional.
    private var preferredScreen: NSScreen? {
        NSScreen.screens.max { $0.safeAreaInsets.top < $1.safeAreaInsets.top } ?? NSScreen.main
    }
}
