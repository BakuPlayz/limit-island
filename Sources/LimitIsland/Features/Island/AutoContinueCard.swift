import SwiftUI

/// Offers to pick the work back up once Claude's five-hour window returns, then
/// stands as the receipt for that promise.
///
/// One view for both states because they are one thing to the person reading them:
/// the question, and then the answer they gave to it, in the same place. The cost
/// line is part of the row rather than a tooltip — resuming re-sends the whole
/// conversation, and that is spent from the very window being waited for, so it has
/// to be readable before anyone agrees rather than discoverable afterwards.
struct AutoContinueCard: View {
    let sessions: [AgentSession]
    let resetAt: Date
    let scheduled: ScheduledContinue?
    let outcome: AutoContinueStore.Outcome?
    let onSchedule: (AgentSession, String) -> Void
    let onDismiss: () -> Void
    let onCancel: () -> Void
    let onAcknowledge: () -> Void
    let onComposing: (Bool) -> Void

    @State private var chosenSessionID: String?
    @State private var isWritingMessage = false

    /// How many `NotchLayout.rowHeight` units the window has to reserve for this
    /// card. It lives here rather than in the controller so the view that draws it
    /// and the frame that has to hold it cannot drift apart — `AutoContinueCardLayoutTests`
    /// measures the rendered card against exactly this.
    ///
    /// The numbers come from that measurement: the offer is a header, two actions
    /// and the cost note, and a picker adds its own label plus a row per session.
    nonisolated static func rowBudget(sessionCount: Int, isArmed: Bool) -> Int {
        if isArmed { return 2 }
        return sessionCount > 1 ? 4 + sessionCount : 3
    }

    private var accent: Color { Provider.claude.color }

    /// `ResetCountdown.absolute` is optional only because its input is; these dates
    /// are not.
    private func clockTime(_ date: Date) -> String {
        ResetCountdown.absolute(date) ?? date.formatted(date: .omitted, time: .shortened)
    }

    /// The session the actions apply to. With one session there is nothing to pick,
    /// so the picker is skipped and this is simply it.
    private var target: AgentSession? {
        if let chosenSessionID { return sessions.first { $0.id == chosenSessionID } }
        return sessions.count == 1 ? sessions.first : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let outcome {
                outcomeRow(outcome)
            } else if let scheduled {
                armedRow(scheduled)
            } else {
                offer
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(red: 0.15, green: 0.16, blue: 0.18), in: RoundedRectangle(cornerRadius: 8)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8).stroke(accent.opacity(0.35), lineWidth: 1)
        )
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
    }

    // MARK: - Offer

    @ViewBuilder
    private var offer: some View {
        header

        if isWritingMessage, let target {
            InlineComposer(
                prompt: "What should Claude pick up with?",
                placeholder: "Type the message to send after the reset",
                accent: accent,
                onSubmit: { message in
                    isWritingMessage = false
                    onSchedule(target, message)
                },
                onCancel: { isWritingMessage = false },
                onComposing: onComposing
            )
        } else {
            // Which session comes first: an action that has not been aimed at
            // anything yet is not an action anyone can safely take.
            if sessions.count > 1 {
                Text("Which session?")
                    .islandFont(size: 10.5)
                    .foregroundStyle(.white.opacity(0.55))
                ForEach(sessions) { session in
                    ChoiceRow(
                        label: session.project ?? session.title,
                        description: session.terminal?.displayName,
                        accent: accent,
                        isSelected: session.id == chosenSessionID,
                        isEnabled: true
                    ) {
                        chosenSessionID = session.id
                    }
                }
            }

            HStack(spacing: 8) {
                AutoContinueButton(
                    title: "Continue with the coding",
                    emphasised: true,
                    isEnabled: target != nil
                ) {
                    guard let target else { return }
                    onSchedule(target, AutoContinueStore.defaultMessage)
                }
                AutoContinueButton(title: "Write a message…", emphasised: false, isEnabled: target != nil) {
                    isWritingMessage = true
                }
            }

            costNote
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "clock.arrow.circlepath")
                .islandFont(size: 12, weight: .semibold)
                .foregroundStyle(accent)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 1) {
                Text("Claude's 5-hour window is nearly out")
                    .islandFont(size: 12, weight: .semibold)
                    .foregroundStyle(accent)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Resume automatically a minute after it resets, around \(clockTime(resetAt)).")
                    .islandFont(size: 10.5)
                    .foregroundStyle(.white.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            // Its own hit area, as on the forecast banner: nothing about dismissing
            // should be reachable by aiming at one of the actions.
            Image(systemName: "xmark")
                .islandFont(size: 10, weight: .semibold)
                .foregroundStyle(.white.opacity(0.55))
                .padding(6)
                .contentShape(Rectangle())
                .onTapGesture(perform: onDismiss)
                .help("Don't ask again for this window")
        }
    }

    /// The part nobody would guess and everybody pays. A resumed conversation is
    /// re-sent in full before Claude can answer anything, and that read comes out of
    /// the window that just reopened.
    @ViewBuilder
    private var costNote: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Resuming re-sends the whole conversation, so the first reply spends part of the new window putting the context back in cache.")
            if let terminal = target?.terminal, TerminalJumper.needsFocusToSend(terminal) {
                Text("There's no way to type into \(terminal.displayName) in the background, so it will come forward for a moment.")
            }
        }
        .islandFont(size: 10)
        .foregroundStyle(.white.opacity(0.5))
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Armed

    private func armedRow(_ plan: ScheduledContinue) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "clock.badge.checkmark")
                .islandFont(size: 12, weight: .semibold)
                .foregroundStyle(accent)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 1) {
                Text("Resuming \(plan.project ?? "Claude") at \(clockTime(plan.fireAt))")
                    .islandFont(size: 12, weight: .semibold)
                    .foregroundStyle(accent)
                    .fixedSize(horizontal: false, vertical: true)
                Text(plan.message)
                    .islandFont(size: 10.5)
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            AutoContinueButton(title: "Cancel", emphasised: false, isEnabled: true, action: onCancel)
        }
    }

    // MARK: - Outcome

    private func outcomeRow(_ outcome: AutoContinueStore.Outcome) -> some View {
        let succeeded = if case .sent = outcome { true } else { false }

        return HStack(alignment: .top, spacing: 9) {
            Image(systemName: succeeded ? "checkmark.circle" : "exclamationmark.triangle")
                .islandFont(size: 12, weight: .semibold)
                .foregroundStyle(succeeded ? accent : Color(red: 1.0, green: 0.42, blue: 0.38))
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 1) {
                Text(outcomeTitle(outcome))
                    .islandFont(size: 12, weight: .semibold)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = outcomeDetail(outcome) {
                    Text(detail)
                        .islandFont(size: 10.5)
                        .foregroundStyle(.white.opacity(0.55))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 8)

            Image(systemName: "xmark")
                .islandFont(size: 10, weight: .semibold)
                .foregroundStyle(.white.opacity(0.55))
                .padding(6)
                .contentShape(Rectangle())
                .onTapGesture(perform: onAcknowledge)
        }
    }

    private func outcomeTitle(_ outcome: AutoContinueStore.Outcome) -> String {
        switch outcome {
        case let .sent(project): "Resumed \(project ?? "Claude")"
        case .sessionGone: "Couldn't resume — that session is gone"
        case .sendFailed: "Couldn't type into that terminal"
        }
    }

    private func outcomeDetail(_ outcome: AutoContinueStore.Outcome) -> String? {
        switch outcome {
        case .sent: nil
        case .sessionGone: "It closed before the window reset."
        case .sendFailed: "Nothing was sent — pick the work up yourself."
        }
    }
}

/// A plain island button. `PermissionCard`'s own is private to it and carries a
/// keyboard shortcut badge this card has no shortcuts for.
private struct AutoContinueButton: View {
    let title: String
    let emphasised: Bool
    let isEnabled: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Text(title)
            .islandFont(size: 11, weight: .medium)
            .foregroundStyle(isEnabled ? .white : .white.opacity(0.35))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(background, in: RoundedRectangle(cornerRadius: 7))
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(.white.opacity(emphasised ? 0 : 0.14), lineWidth: 1)
            )
            .contentShape(Rectangle())
            .onHover { isHovered = $0 && isEnabled }
            .onTapGesture { if isEnabled { action() } }
            .accessibilityAddTraits(.isButton)
    }

    private var background: Color {
        guard isEnabled else { return .white.opacity(0.05) }
        if emphasised { return Provider.claude.color.opacity(isHovered ? 0.45 : 0.3) }
        return .white.opacity(isHovered ? 0.16 : 0.08)
    }
}
