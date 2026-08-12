import SwiftUI

struct MenuBarView: View {
    @ObservedObject var state: QuotaStore
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Limit Island")
                .font(.headline)
            Text("Refreshes local sessions every minute")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Refresh now") { state.refreshAll() }
                .keyboardShortcut("r")
            Button("Settings…") {
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            }
                .keyboardShortcut(",")
            Divider()
            Button("Quit Limit Island") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        .padding(4)
    }
}

struct SettingsView: View {
    @ObservedObject var state: QuotaStore
    let sessions: SessionStore

    var body: some View {
        TabView {
            AccountsSettings(state: state)
                .tabItem { Label("Accounts", systemImage: "person.2") }
            SessionsSettings(state: state, sessions: sessions)
                .tabItem { Label("Agents", systemImage: "terminal") }
        }
        .frame(width: 660, height: 560)
    }
}

// MARK: - Accounts

private struct AccountsSettings: View {
    @ObservedObject var state: QuotaStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Accounts")
                    .font(.system(size: 25, weight: .bold, design: .rounded))
                Text("Track the accounts whose usage appears around the notch. Choose which coding-agent accounts appear on each side in Agents settings.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if !state.availableAccounts.isEmpty {
                    detectedSection
                }

                configuredSection

                HStack {
                    Menu("Add account…") {
                        ForEach(Provider.available) { provider in
                            Button(provider.title) { state.addBrowserAccount(for: provider) }
                        }
                    }
                    .frame(width: 160)
                    Spacer()
                }

                if let signInError = state.signInError {
                    Label(signInError, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                Text("""
                No passwords or chat content are copied into app preferences. Browser-added Codex and \
                Claude accounts keep their own isolated session. A CLI login is read once and then \
                mirrored into a keychain item belonging to Limit Island, so macOS asks for permission \
                a single time rather than on every refresh. Usage values come from each provider's \
                own API and stay blank when a provider does not expose them.
                """)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var detectedSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Detected on this Mac")
                .font(.headline)
            ForEach(state.availableAccounts) { account in
                HStack(spacing: 12) {
                    ProviderLogo(provider: account.provider, size: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(account.label).font(.subheadline)
                        Text("Already signed in via \(account.provider.title) CLI")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Add") { state.add(account) }
                }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    private var configuredSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Tracked accounts")
                .font(.headline)
            if state.visibleMeters.isEmpty {
                Text("No accounts yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            } else {
                List {
                    ForEach(state.visibleMeters) { meter in
                        MeterRow(state: state, meter: meter)
                    }
                    .onMove { state.move(fromOffsets: $0, toOffset: $1) }
                }
                .listStyle(.plain)
                // A configured account can have a last-read line plus one reset
                // line for each provider window.
                .frame(height: CGFloat(state.visibleMeters.count) * 78 + 8)
                .scrollDisabled(true)
            }
        }
    }
}

/// One configured account: identity, rename, sign-in and removal.
private struct MeterRow: View {
    @ObservedObject var state: QuotaStore
    let meter: Meter
    @State private var isRenaming = false
    @State private var draftName = ""

    var body: some View {
        HStack(spacing: 12) {
            ProviderLogo(provider: meter.provider, size: 26)
            VStack(alignment: .leading, spacing: 1) {
                if isRenaming {
                    TextField("Name", text: $draftName, onCommit: commitRename)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 180)
                } else {
                    Text(meter.displayLabel).font(.headline)
                }
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if usage.status == .ready {
                    if resetSchedule.isEmpty {
                        Text("Reset time unavailable")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(resetSchedule, id: \.self) { schedule in
                            Text(schedule)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Spacer()

            Menu {
                Button(isRenaming ? "Finish renaming" : "Rename…") {
                    if isRenaming { commitRename() } else {
                        draftName = meter.customLabel ?? meter.detectedLabel ?? ""
                        isRenaming = true
                    }
                }
                Button("Open sign-in…") { state.openLoginWindow(for: meter) }
                Button("Sign out") { Task { await state.signOut(meter) } }
                Divider()
                Button("Remove", role: .destructive) { state.remove(meter) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 40)
        }
        .padding(.vertical, 4)
    }

    private func commitRename() {
        state.rename(meter, to: draftName)
        isRenaming = false
    }

    private var statusText: String {
        switch usage.status {
        case .waitingForSignIn: return "Sign in required"
        case .reading: return "Checking usage…"
        case .unavailable: return "\(meter.provider.title) does not expose usage values"
        case .ready:
            let time = usage.updatedAt?.formatted(date: .omitted, time: .shortened) ?? "now"
            return "Last read \(time)"
        }
    }

    private var usage: SubscriptionUsage {
        state.usage(for: meter)
    }

    /// Reset dates are optional because the page-scraping fallback can read a
    /// percentage without a provider-supplied schedule. Only show dates the
    /// provider actually returned.
    private var resetSchedule: [String] {
        [
            ("5-hour", usage.fiveHourResetAt),
            ("Weekly", usage.weekResetAt)
        ].compactMap { label, resetAt in
            ResetCountdown.settings(resetAt).map { "\(label) reset: \($0)" }
        }
    }
}

// MARK: - Agents

private struct SessionsSettings: View {
    @ObservedObject var state: QuotaStore
    let sessions: SessionStore
    @State private var hookState = HookInstaller.state()
    @State private var codexState = HookInstaller.codexState()
    @State private var installError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Agents")
                    .font(.system(size: 25, weight: .bold, design: .rounded))
                Text("Limit Island watches the coding agents running in your terminals so you can see, approve and jump to them from the notch.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                pinsSection
                hookSection
                codexSection
                capabilitiesSection
                approvalSection
                liveSection
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var agentMeters: [Meter] {
        state.visibleMeters.filter { $0.provider == .openAI || $0.provider == .claude }
    }

    private var pinsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Pinned agents")
                .font(.headline)
            Text("Choose the Codex or Claude account whose logo and quota appear on each side of the notch. Both slots keep the same width; an unpinned side stays blank. Clicking either readout opens all active agents.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if agentMeters.isEmpty {
                Text("Add a Codex or Claude account in Accounts to pin it here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                pinPicker("Left of notch", selection: leftPin)
                pinPicker("Right of notch", selection: rightPin)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    private var leftPin: Binding<UUID?> {
        Binding(get: { state.leftPinnedMeterID }, set: { select($0, side: .left) })
    }

    private var rightPin: Binding<UUID?> {
        Binding(get: { state.rightPinnedMeterID }, set: { select($0, side: .right) })
    }

    private func pinPicker(_ label: String, selection: Binding<UUID?>) -> some View {
        Picker(label, selection: selection) {
            Text("No pin").tag(UUID?.none)
            ForEach(agentMeters) { meter in
                Text("\(meter.provider.title) — \(meter.displayLabel)").tag(Optional(meter.id))
            }
        }
    }

    private func select(_ id: UUID?, side: NotchSide) {
        guard let id else {
            state.unpin(side)
            return
        }
        guard let meter = agentMeters.first(where: { $0.id == id }) else { return }
        state.pin(meter, to: side)
    }

    private var hookSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(hookStateTitle, systemImage: hookStateSymbol)
                    .font(.headline)
                Spacer()
                if hookState == .installed {
                    Button("Remove hooks") { perform(HookInstaller.uninstall) }
                } else {
                    Button(hookState == .stale ? "Reinstall hooks" : "Install hooks") {
                        perform(HookInstaller.install)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            Text("""
            Installing adds Limit Island's hooks to \(HookInstaller.claudeSettingsURL.path). Your existing \
            settings are kept, a timestamped backup is written to \(HookInstaller.backupsDirectory.path) \
            first, and removing takes out only the entries Limit Island added.
            """)
                .font(.caption)
                .foregroundStyle(.secondary)

            automaticNotice

            Text("""
            If Limit Island is not running, the hooks do nothing at all — they exit immediately and your \
            CLI behaves exactly as it would without them.
            """)
                .font(.caption)
                .foregroundStyle(.secondary)
            automaticNotice

            if let installError {
                Label(installError, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    private var codexSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(codexStateTitle, systemImage: codexState == .installed ? "checkmark.circle.fill" : "circle.dashed")
                    .font(.headline)
                Spacer()
                if codexState == .installed {
                    Button("Remove") { perform(HookInstaller.uninstallCodex) }
                } else {
                    Button(codexState == .stale ? "Reinstall" : "Install") {
                        perform(HookInstaller.installCodex)
                    }
                }
            }
            Text("""
            Codex sessions are read from the transcripts it already writes to \
            ~/.codex/sessions, so activity appears with no setup at all. Installing \
            adds one `notify` line to \(HookInstaller.codexConfigURL.path) — that is \
            the only moment Codex tells us which terminal it is in, so jumping to a \
            Codex session needs it. Your existing settings, including every \
            [projects.*] entry, are left exactly as they are.
            """)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    private var codexStateTitle: String {
        switch codexState {
        case .installed: "Codex notify installed"
        case .absent: "Codex notify not installed"
        case .stale: "Codex notify points at an older copy"
        }
    }

    @ViewBuilder
    private var automaticNotice: some View {
        if let notice = HookInstaller.automaticNotice {
            Label(notice, systemImage: "checkmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// The honest limits, stated up front rather than discovered.
    private var capabilitiesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("What each CLI supports")
                .font(.headline)
            capability(.claude, monitor: true, approve: true, note: "Full support through Claude Code's hooks.")
            capability(.openAI, monitor: true, approve: false, note: "Sessions, live activity and jump come from Codex's own session files and its notify hook. Codex has no hook that waits for a reply, so it cannot be answered from the notch.")
        }
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    private func capability(_ provider: Provider, monitor: Bool, approve: Bool, note: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            ProviderLogo(provider: provider, size: 20)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(provider.title).font(.subheadline).bold()
                    tag("Monitor", on: monitor)
                    tag("Approve", on: approve)
                    tag("Jump", on: true)
                }
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func tag(_ title: String, on: Bool) -> some View {
        Text(title)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(on ? Color.accentColor.opacity(0.22) : Color.secondary.opacity(0.14),
                        in: Capsule())
            .foregroundStyle(on ? Color.accentColor : Color.secondary)
    }

    private var approvalSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Approve from the notch")
                .font(.headline)
            TextField("Tools", text: Binding(
                get: { sessions.approvalMatcher },
                set: { sessions.approvalMatcher = $0 }
            ))
            .textFieldStyle(.roundedBorder)
            Text("""
            Tool names separated by |. Claude Code asks Limit Island about these before running them. \
            Anything you have already allowed or denied in your own Claude Code permission settings is \
            honoured first and never shown here, so adding a tool does not re-introduce prompts you had \
            turned off. If you do not answer within eight minutes, the decision goes back to the \
            terminal prompt — Limit Island never denies on your behalf.
            """)
                .font(.caption)
                .foregroundStyle(.secondary)
            Label("""
            Sessions running in auto-accept (⇧⇥) or with permissions bypassed are never interrupted. \
            You already answered; the session still appears in the panel, it just does not ask. In plan \
            mode only the finished plan is offered for approval.
            """, systemImage: "bolt.badge.automatic")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Reset to default") { sessions.approvalMatcher = SessionStore.defaultMatcher }
                .font(.caption)
        }
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    private var liveSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Sessions right now")
                .font(.headline)
            if sessions.sessions.isEmpty {
                Text("None. Start an agent in a terminal to confirm the hooks are working.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(sessions.sessions) { session in
                    HStack(spacing: 10) {
                        ProviderLogo(provider: session.provider, size: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(session.title).font(.subheadline)
                            Text(session.activity.detail ?? "Running")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(session.terminal?.displayName ?? "Terminal")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Jump") { _ = TerminalJumper.jump(to: session) }
                    }
                }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    private var hookStateTitle: String {
        switch hookState {
        case .installed: "Hooks installed"
        case .absent: "Hooks not installed"
        case .stale: "Hooks point at an older copy of Limit Island"
        }
    }

    private var hookStateSymbol: String {
        switch hookState {
        case .installed: "checkmark.circle.fill"
        case .absent: "circle.dashed"
        case .stale: "exclamationmark.triangle.fill"
        }
    }

    private func perform(_ action: () throws -> Void) {
        do {
            try action()
            installError = nil
        } catch {
            installError = error.localizedDescription
        }
        hookState = HookInstaller.state()
        codexState = HookInstaller.codexState()
    }
}
