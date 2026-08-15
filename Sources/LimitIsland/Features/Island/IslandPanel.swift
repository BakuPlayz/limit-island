import SwiftUI

/// What the notch window is currently showing.
enum IslandPresentation: Equatable {
    /// Content sits either side of the physical camera housing.
    case strip
    /// One panel hanging below the notch, overlapping the desktop.
    case expanded
    /// No camera housing on this display: a floating bar at the top centre.
    case floatingBar
}

/// The whole notch surface, in whichever presentation the presenter has chosen.
///
/// Built once, at launch. Everything variable arrives through `presenter` or one of
/// the two stores, so SwiftUI updates in place — see `IslandWindowController` for
/// why replacing this view was a crash rather than merely wasteful.
struct IslandContent: View {
    @ObservedObject var quota: QuotaStore
    let sessions: SessionStore
    let codexReset: CodexResetStore
    let presenter: IslandPresenter
    let onToggle: () -> Void
    let onJump: (AgentSession) -> Void

    var body: some View {
        Group {
            switch presenter.presentation {
            case .strip: strip
            case .expanded: panel
            case .floatingBar: floatingBar
            }
        }
    }



    // MARK: - Resting

    /// Pinned quota accounts flank the housing in the same logo-first order on
    /// both sides. The expanded header reuses this exact row and its padding.
    ///
    /// Each side is hard-framed to the width the controller measured and clipped to
    /// it. That is what keeps the readout out of the notch: the middle is a fixed
    /// gap exactly as wide as the camera housing, and neither side can grow into it
    /// even if a measurement is ever wrong.
    private var strip: some View {
        pinnedReadoutRow(expanded: false)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The hardware notch is pure black, so the bridge between the two sides
        // uses the same exact #000 rather than a translucent system material.
        .background(Color.black)
        .clipShape(UnevenRoundedRectangle(
            topLeadingRadius: 0,
            bottomLeadingRadius: 13,
            bottomTrailingRadius: 13,
            topTrailingRadius: 0
        ))
        .modifier(TapToToggle(action: onToggle))
    }

    /// The source of truth for both closed and expanded pinned quotas. Keeping one
    /// row eliminates the padding and alignment jump during expansion.
    private func pinnedReadoutRow(expanded: Bool) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 0) {
                Spacer(minLength: NotchLayout.outerEdgePadding)
                if let meter = quota.leftPinnedMeter {
                    QuotaReadout(
                        meter: meter,
                        usage: leftUsage,
                        mirrored: true,
                        readsRightToLeft: true,
                        showsFiveHour: expanded ? false : meter.provider != .openAI,
                        showsWeek: expanded || meter.provider == .openAI
                    )
                }
            }
            .padding(.trailing, NotchLayout.notchInset)
            .frame(width: presenter.leftWidth, alignment: .trailing)
            .clipped()

            Color.clear.frame(width: presenter.notchWidth)

            HStack(spacing: 0) {
                if let meter = quota.rightStripMeter {
                    QuotaReadout(
                        meter: meter,
                        usage: rightUsage,
                        showsFiveHour: expanded ? false : meter.provider != .openAI,
                        showsWeek: expanded || meter.provider == .openAI
                    )
                }
                Spacer(minLength: NotchLayout.outerEdgePadding)
            }
            .padding(.leading, NotchLayout.notchInset)
            .frame(width: presenter.rightWidth, alignment: .leading)
            .clipped()
        }
    }

    // MARK: - Expanded

    private var panel: some View {
        VStack(spacing: 0) {
            notchBand
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.black)
        .clipShape(UnevenRoundedRectangle(
            topLeadingRadius: 0,
            bottomLeadingRadius: NotchLayout.panelCornerRadius,
            bottomTrailingRadius: NotchLayout.panelCornerRadius,
            topTrailingRadius: 0
        ))
    }

    /// The panel's top row sits at the same height as the camera housing, so its
    /// content is laid out around the housing rather than across it: quota to the
    /// left, refresh state to the right, and a gap the width of the notch between.
    /// The band is at least as tall as the housing so the divider below it clears
    /// the notch on every display.
    private var notchBand: some View {
        Group {
            if hasPinnedMeters {
                pinnedNotchBand
            } else {
                headlineNotchBand
            }
        }
        .frame(height: presenter.headerHeight)
        .modifier(TapToToggle(action: onToggle))
    }

    private var pinnedNotchBand: some View {
        pinnedReadoutRow(expanded: true)
            .overlay(alignment: .trailing) {
                if quota.isRefreshing {
                    Text("Refreshing…")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.white.opacity(0.35))
                        .padding(.trailing, 8)
                }
            }
    }

    private var headlineNotchBand: some View {
        HStack(spacing: 0) {
            QuotaReadout(
                meter: quota.headlineMeter,
                usage: headlineUsage,
                showsAccountLabel: quota.visibleMeters.count > 1
            )
            .padding(.leading, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipped()

            Color.clear.frame(width: presenter.notchWidth)

            HStack(spacing: 0) {
                Spacer(minLength: 0)
                if quota.isRefreshing {
                    Text("Refreshing…")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.white.opacity(0.35))
                }
            }
            .padding(.trailing, 12)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .clipped()
        }
    }

    private var floatingBar: some View {
        VStack(spacing: 0) {
            // No housing to work around here, so the same row lays out edge to edge.
            HStack(spacing: 0) {
                QuotaReadout(
                    meter: quota.headlineMeter,
                    usage: headlineUsage,
                    showsAccountLabel: quota.visibleMeters.count > 1
                )
                Spacer(minLength: 8)
                if quota.isRefreshing {
                    Text("Refreshing…")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.white.opacity(0.35))
                }
            }
            .padding(.horizontal, 12)
            .frame(height: presenter.headerHeight)

            if !sessions.sessions.isEmpty || !sessions.pending.isEmpty || showsCodexResetBanner {
                content
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.black.opacity(0.92))
        .clipShape(RoundedRectangle(cornerRadius: NotchLayout.panelCornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: NotchLayout.panelCornerRadius)
                .stroke(.white.opacity(0.09), lineWidth: 1)
        )
    }

    /// The forecast is about Codex quota, so it is noise to anyone without a Codex
    /// account, and it never covers a card or a sheet the person is answering.
    private var showsCodexResetBanner: Bool {
        guard sessions.activeInteraction == nil, presenter.jumpSheet == nil else { return false }
        return codexReset.shouldPrompt(hasCodexAccount: quota.hasCodexAccount)
    }

    @ViewBuilder
    private var content: some View {
        if let interaction = sessions.activeInteraction {
            ScrollView {
                activeCard(interaction)
                    .id(interaction.id)
                    .padding(.horizontal, 8)
                    .padding(.top, 8)
                    .padding(.bottom, 12)
                    .background {
                        GeometryReader { geometry in
                            Color.clear.preference(
                                key: InteractionHeightKey.self, value: ceil(geometry.size.height)
                            )
                        }
                    }
            }
            .scrollIndicators(.visible)
            .onPreferenceChange(InteractionHeightKey.self) { height in
                guard height > 0 else { return }
                Task { @MainActor in presenter.set(\.interactionHeight, to: height) }
            }
            .onChange(of: interaction.id) { _, _ in
                presenter.set(\.interactionHeight, to: 0)
            }
        } else if let sheet = presenter.jumpSheet {
            jumpSheet(sheet)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    // Above the sessions rather than inside them: it is about the
                    // account, not about any one agent.
                    if showsCodexResetBanner, let forecast = codexReset.forecast {
                        CodexResetBanner(forecast: forecast) { codexReset.dismiss() }
                    }
                    if sessions.sessions.isEmpty {
                            emptyState
                    } else {
                        ForEach(sessions.sessions) { session in
                            SessionRow(session: session) { onJump(session) }
                        }
                    }
                }
                .padding(.vertical, 8)
            }
            .scrollIndicators(.visible)
        }
    }

    @ViewBuilder
    private func activeCard(_ interaction: SessionStore.ActiveInteraction) -> some View {
        switch interaction {
        case let .pending(request):
            PermissionCard(
                request: request,
                queueCount: sessions.waitingInteractionCount,
                project: sessions.session(id: request.sessionID)?.project,
                onAllow: { sessions.allow(request) },
                onDeny: { sessions.deny(request) },
                onAnswer: { sessions.answer(request, answers: $0) },
                onApprovePlan: { sessions.approvePlan(request, automatic: $0) },
                onRequestChanges: { sessions.requestPlanChanges(request, feedback: $0) },
                onJump: {
                    guard let session = sessions.session(id: request.sessionID) else { return }
                    onJump(session)
                },
                onQuestionState: { _, _, handler in presenter.questionShortcut = handler }
            )
            .onDisappear { presenter.questionShortcut = nil }

        case let .codex(session, state):
            CodexQuestionCard(
                question: state.question,
                queueCount: sessions.waitingInteractionCount,
                onSelection: { selections, multiSelect in
                    TerminalJumper.answerCodexSelection(selections, multiSelect: multiSelect, in: session)
                },
                onFinished: { sessions.dismissCodexQuestion(sessionID: session.id) },
                onFallback: { onJump(session) },
                onQuestionState: { handler in presenter.questionShortcut = handler }
            )
            .onDisappear { presenter.questionShortcut = nil }
        }
    }

    @ViewBuilder
    private func jumpSheet(_ sheet: IslandPresenter.JumpSheet) -> some View {
        switch sheet {
        case let .chooser(sessionID, destinations):
            VStack(alignment: .leading, spacing: 6) {
                sheetHeader("Choose terminal", subtitle: "More than one tab matches this agent.")
                ForEach(destinations) { destination in
                    Button {
                        sessions.selectDestination(destination, for: sessionID)
                        guard let session = sessions.session(id: sessionID) else { return }
                        presenter.jumpSheet = nil
                        onJump(session)
                    } label: {
                        HStack {
                            Image(systemName: "terminal")
                            VStack(alignment: .leading, spacing: 1) {
                                Text(destination.title).lineLimit(1)
                                Text(destination.workingDirectory ?? destination.terminalName)
                                    .font(.system(size: 9.5)).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Image(systemName: "arrow.up.forward.app")
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(8)
                    .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
                }
                Button("Back") { presenter.jumpSheet = nil }.font(.caption)
            }
            .sheetContainer()

        case let .automation(sessionID, terminal):
            VStack(alignment: .leading, spacing: 8) {
                sheetHeader("Allow \(terminal) control", subtitle: "macOS blocked exact tab switching for Limit Island.")
                HStack {
                    Button("Open Privacy Settings") { TerminalJumper.openAutomationSettings() }
                    Button("Retry") {
                        guard let session = sessions.session(id: sessionID) else { return }
                        presenter.jumpSheet = nil
                        onJump(session)
                    }
                    Button("Back") { presenter.jumpSheet = nil }
                }
                .font(.caption)
            }
            .sheetContainer()

        case let .setup(_, terminal):
            VStack(alignment: .leading, spacing: 8) {
                sheetHeader("Enable exact \(terminal) switching", subtitle: "This adds a backed-up, socket-only remote-control include. Restart kitty afterward.")
                HStack {
                    Button("Enable") {
                        do {
                            try TerminalIntegrationSetup.enableKitty()
                            presenter.jumpSheet = .notice("kitty integration enabled. Restart kitty to use exact switching.")
                        } catch {
                            presenter.jumpSheet = .notice(error.localizedDescription)
                        }
                    }
                    Button("Cancel") { presenter.jumpSheet = nil }
                }
                .font(.caption)
            }
            .sheetContainer()

        case let .notice(message):
            VStack(alignment: .leading, spacing: 8) {
                sheetHeader("Terminal", subtitle: message)
                Button("Done") { presenter.jumpSheet = nil }.font(.caption)
            }
            .sheetContainer()
        }
    }

    private func sheetHeader(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 12, weight: .semibold))
            Text(subtitle).font(.system(size: 10)).foregroundStyle(.white.opacity(0.55))
        }
    }

    private var emptyState: some View {
        VStack(spacing: 3) {
            Text("No agents running")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
            // Read from the presenter, not from `HookInstaller.state()` — this is a
            // view body, and that call reads a file off disk.
            Text(presenter.hookState == .installed
                 ? "Start Claude Code in a terminal and it will appear here."
                 : "Install the hooks in Settings to see sessions here.")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.32))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .frame(height: NotchLayout.rowHeight)
    }

    private var headlineUsage: SubscriptionUsage? {
        quota.headlineMeter.map { quota.usage(for: $0) }
    }

    private var leftUsage: SubscriptionUsage? {
        quota.leftPinnedMeter.map { quota.usage(for: $0) }
    }

    private var rightUsage: SubscriptionUsage? {
        quota.rightStripMeter.map { quota.usage(for: $0) }
    }

    private var hasPinnedMeters: Bool {
        quota.leftPinnedMeter != nil || quota.rightStripMeter != nil
    }
}

private struct InteractionHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}


/// Opening and closing is a click on the strip or on the panel's top band — never on
/// the body, where a click belongs to a session row or an answer button. Hover used
/// to do this and fought the hardware: the pointer's route to the strip runs through
/// the camera housing, which cannot be hovered at all.
private struct TapToToggle: ViewModifier {
    let action: () -> Void

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
    }
}
