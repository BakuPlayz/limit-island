import AppKit
import Carbon
import Combine
import SwiftUI

/// A panel that takes key status only while it is asking to be typed into.
///
/// `NSPanel` differs from `NSWindow` here: a borderless `NSWindow` refuses key
/// status, but a borderless `NSPanel` accepts it — which is what makes
/// Spotlight-style panels possible, and what let SwiftUI put keyboard focus on the
/// first control inside the permission card. A focused control can be fired by
/// Return or Space, so a permission request could be answered by a keystroke aimed
/// at something else entirely. Hence the default of `false`.
///
/// `allowsKey` is raised only while a card is showing a text field, and every other
/// control on that card is disabled for exactly as long — so there is nothing a
/// stray Return could fire. It is never left raised: see
/// `IslandWindowController.syncTextEntry`.
private final class NeverKeyPanel: NSPanel {
    var allowsKey = false
    override var canBecomeKey: Bool { allowsKey }
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
/// The panel is non-activating and, since a card once answered itself, refuses key
/// status. That is what lets someone answer a permission request without their editor
/// losing focus, and why `handleHotKey` exists: shortcuts reach a window that is not
/// key. The single exception is typing — macOS delivers keystrokes only to the active
/// application — so `syncTextEntry` lends the panel focus while a text field is on
/// screen and hands it straight back to whichever app had it.
@MainActor
final class IslandWindowController: NSObject {
    private let quota: QuotaStore
    private let sessions: SessionStore
    private let codexReset: CodexResetStore
    private let autoContinue: AutoContinueStore
    private let presenter = IslandPresenter()
    private let panel = IslandWindowController.makePanel()
    private var cancellables = Set<AnyCancellable>()
    private var isVisible = false

    /// Whether the person has opened the panel. Hover used to do this, which
    /// fought the hardware: the pointer's path to the strip runs through the camera
    /// housing, which cannot be hovered, so opening it was a matter of luck.
    private var isOpen = false
    /// Actual rendered state. This can be true while `isOpen` is false when an
    /// interaction expanded the panel automatically.
    private var isExpanded = false
    /// Waiting rows the person explicitly collapsed. Removed as soon as a session
    /// resumes, so a later request from the same session can surface normally.
    private var dismissedWaitingSessionIDs: Set<String> = []
    private var hotKeyHandler: EventHandlerRef?
    private var hotKeys: [EventHotKeyRef?] = []
    /// Installed only while the panel is open, so a click anywhere else closes it.
    private var outsideClickMonitor: Any?
    /// Whichever application was frontmost when a composer opened, so typing an
    /// answer costs the person their insertion point only for as long as they type.
    private var applicationBeforeTextEntry: NSRunningApplication?

    init(
        quota: QuotaStore, sessions: SessionStore, codexReset: CodexResetStore,
        autoContinue: AutoContinueStore
    ) {
        self.quota = quota
        self.sessions = sessions
        self.codexReset = codexReset
        self.autoContinue = autoContinue
        super.init()

        presenter.refreshHookState()

        // Built once. The closures capture the controller weakly and are the only
        // way SwiftUI talks back to it.
        panel.contentView = NSHostingView(rootView: IslandContent(
            quota: quota,
            sessions: sessions,
            codexReset: codexReset,
            autoContinue: autoContinue,
            presenter: presenter,
            onToggle: { [weak self] in self?.toggle() },
            onJump: { [weak self] session in
                self?.handleJump(session)
            }
        ))

        // Not a Combine publisher like the quota stores: this one is `@Observable`,
        // which SwiftUI follows on its own but the window frame does not.
        codexReset.onChange = { [weak self] in self?.position() }
        autoContinue.onChange = { [weak self] in self?.position() }

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

    /// The island gets out of the way on the click, not on the answer. Resolving a
    /// terminal means several subprocesses, and waiting for them before closing is
    /// what made a click feel late; the sheets below re-open the panel in the rare
    /// case the jump needs something from the person.
    private func handleJump(_ session: AgentSession) {
        presenter.jumpSheet = nil
        collapse()
        Task { @MainActor [weak self] in
            let resolution = await TerminalJumper.jump(to: session)
            self?.finishJump(resolution, for: session)
        }
    }

    private func finishJump(_ resolution: JumpResolution, for session: AgentSession) {
        switch resolution {
        case .jumped:
            presenter.jumpSheet = nil
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
        for hotKey in hotKeys { if let hotKey { UnregisterEventHotKey(hotKey) } }
        hotKeys.removeAll()
        if let hotKeyHandler { RemoveEventHandler(hotKeyHandler) }
        hotKeyHandler = nil
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
            _ = sessions.codexQuestions.count
            _ = presenter.jumpSheet
            _ = presenter.interactionHeight
            _ = presenter.isComposing
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.position()
                self?.syncHotKeys()
                self?.syncTextEntry()
                self?.observeSessions()
            }
        }
    }

    /// Lends the panel keyboard focus while a card is showing a text field, and takes
    /// it back the moment the field goes away — including when the interaction times
    /// out from underneath it, since that also clears `isComposing`.
    ///
    /// macOS delivers key events only to the active application, so there is no
    /// version of typing here that does not briefly take focus. What this does that
    /// the modal dialog it replaced never did is give it back.
    private func syncTextEntry() {
        let composing = presenter.isComposing
        guard composing != panel.allowsKey else { return }
        if composing {
            applicationBeforeTextEntry = NSWorkspace.shared.frontmostApplication
            panel.allowsKey = true
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKey()
        } else {
            panel.allowsKey = false
            panel.resignKey()
            if let previous = applicationBeforeTextEntry, !previous.isTerminated,
               previous.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                previous.activate()
            }
            applicationBeforeTextEntry = nil
        }
    }

    // MARK: - Opening and closing

    /// Called from the strip's tap gesture. Like every SwiftUI callback here it
    /// records intent and lets a `Task` reach the window on a later turn — see the
    /// note on the class for why touching geometry inline was a crash.
    private func toggle() {
        if isExpanded { collapse() } else { setOpen(true) }
    }

    private func setOpen(_ open: Bool) {
        guard open != isOpen else { return }
        // A card is a question that has to be answered. Clicking away must not
        // dismiss it — only answering it, or its own timeout, takes it off screen.
        if !open, sessions.activeInteraction != nil { return }
        isOpen = open
        updateOutsideClickMonitor()
        Task { @MainActor [weak self] in self?.position() }
    }

    /// Collapse requests must reposition even when the panel was auto-expanded and
    /// the user-open flag was already false. That mismatch previously left a done
    /// session panel stuck on screen.
    private func collapse() {
        guard sessions.activeInteraction == nil else { return }
        dismissedWaitingSessionIDs.formUnion(
            sessions.sessions.lazy.filter { $0.activity.isWaiting }.map(\.id)
        )
        isOpen = false
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
                Task { @MainActor [weak self] in self?.collapse() }
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
        let waitingIDs = Set(sessions.sessions.lazy.filter { $0.activity.isWaiting }.map(\.id))
        dismissedWaitingSessionIDs.formIntersection(waitingIDs)
        let hasUndismissedWaiting = !waitingIDs.subtracting(dismissedWaitingSessionIDs).isEmpty
        let wantsExpansion = isOpen || !sessions.pending.isEmpty || hasUndismissedWaiting
        isExpanded = wantsExpansion

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
                cards: sessions.waitingInteractionCount > 0 ? 1 : 0,
                headerHeight: presenter.headerHeight,
                cardHeight: presenter.interactionHeight > 0 ? presenter.interactionHeight : nil
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
                cards: sessions.waitingInteractionCount > 0 ? 1 : 0,
                headerHeight: presenter.headerHeight,
                cardHeight: presenter.interactionHeight > 0 ? presenter.interactionHeight : nil
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
        case let .chooser(_, destinations): return max(2, destinations.count + 1)
        case .automation, .setup, .notice: return 2
        case nil:
            guard sessions.activeInteraction == nil else { return 0 }
            // The reset banner is a row of the same height, and the list keeps its
            // empty-state row underneath it.
            var rows = max(sessions.sessions.count, 1)
            var extra = 0
            if codexReset.shouldPrompt(hasCodexAccount: quota.hasCodexAccount) { extra += 1 }
            // The auto-continue card is taller than a row: an offer carries a
            // picker, two actions and the cost note, and an armed or finished one
            // is a single row's worth of text.
            extra += autoContinueRows
            guard extra > 0 else { return sessions.sessions.count }
            rows += extra
            return rows
        }
    }

    /// How many `rowHeight` units the auto-continue card needs, or zero when it is
    /// not showing. It has to agree with `IslandPanel.showsAutoContinue` — the panel
    /// decides what to draw and this decides what to leave room for, and a
    /// disagreement is a card clipped by its own window.
    private var autoContinueRows: Int {
        guard sessions.activeInteraction == nil, presenter.jumpSheet == nil else { return 0 }
        let claudeSessions = sessions.sessions.filter { $0.provider == .claude && $0.terminal != nil }
        if autoContinue.scheduled != nil || autoContinue.lastOutcome != nil {
            return AutoContinueCard.rowBudget(sessionCount: claudeSessions.count, isArmed: true)
        }
        guard autoContinue.shouldOffer(
            drainedResetAt: quota.drainedClaudeWindow?.resetAt,
            hasClaudeSession: !claudeSessions.isEmpty
        ) else { return 0 }
        return AutoContinueCard.rowBudget(sessionCount: claudeSessions.count, isArmed: false)
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
    /// Carbon hot keys see the chord wherever the person is actually typing without
    /// requiring Input Monitoring access. `NSEvent` global monitors silently stop
    /// receiving key events when that privacy permission is absent.
    ///
    /// It is deliberately **not** bound to ⌘Y and ⌘N. A global monitor fires for
    /// every application, and those two are already taken: ⌘Y is Redo in a number
    /// of apps and ⌘N is New almost everywhere. Hitting either while a card
    /// happened to be waiting would silently approve or refuse a permission request
    /// the person never looked at — which is exactly the failure this feature must
    /// not have. Adding Control makes the chord one nothing else claims.
    private func installKeyMonitor() {
        var type = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID), nil,
                MemoryLayout<EventHotKeyID>.size, nil, &identifier
            )
            guard status == noErr else { return status }
            let controller = Unmanaged<IslandWindowController>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in controller.handleHotKey(identifier.id) }
            return noErr
        }, 1, &type, context, &hotKeyHandler)

        syncHotKeys()
    }

    /// Register only while an interaction is visible. Carbon hot keys consume the
    /// chord, so leaving them installed while idle would steal it from other apps.
    private func syncHotKeys() {
        for hotKey in hotKeys { if let hotKey { UnregisterEventHotKey(hotKey) } }
        hotKeys.removeAll()
        guard sessions.activeInteraction != nil else { return }

        let bindings: [(UInt32, UInt32)] = [
            (1, UInt32(kVK_ANSI_Y)), (2, UInt32(kVK_ANSI_N)),
            (11, UInt32(kVK_ANSI_1)), (12, UInt32(kVK_ANSI_2)),
            (13, UInt32(kVK_ANSI_3)), (14, UInt32(kVK_ANSI_4))
        ]
        let modifiers = UInt32(cmdKey | controlKey)
        for (id, keyCode) in bindings {
            var reference: EventHotKeyRef?
            let identifier = EventHotKeyID(signature: 0x4C49534C, id: id) // LISL
            if RegisterEventHotKey(
                keyCode, modifiers, identifier, GetApplicationEventTarget(), 0, &reference
            ) == noErr {
                hotKeys.append(reference)
            }
        }
    }

    private func handleHotKey(_ id: UInt32) {
        // Only the visible FIFO interaction owns these registered chords.
        if (11...14).contains(id), let shortcut = presenter.questionShortcut {
            shortcut(Int(id - 11))
            return
        }

        // A queued request that is not visible must never be answerable by a global
        // shortcut. In particular, a Codex question may be older than a Claude
        // permission card even though both are waiting.
        guard case let .pending(request)? = sessions.activeInteraction else { return }

        switch id {
        case 1:
            // On a plan card the primary chord means the primary row: approving a plan
            // is always a choice of build mode, never a bare allow.
            if case .plan = request.kind {
                Log.hooks.debug("shortcut: approve plan (auto)")
                sessions.approvePlan(request, automatic: true)
            } else {
                Log.hooks.debug("shortcut: allow")
                sessions.allow(request)
            }
        case 2:
            Log.hooks.debug("shortcut: deny")
            sessions.deny(request)
        default:
            break
        }
    }

    // MARK: - Window

    private static func makePanel() -> NeverKeyPanel {
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
