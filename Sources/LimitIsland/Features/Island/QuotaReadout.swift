import SwiftUI

/// `5h 11% 4h1m │ 7d 2% 6h1m` — one account's two windows on one line.
///
/// The countdown is set at the same size and weight as the percentage, not as a
/// footnote to it. Once a window is low the percentage stops being the useful
/// number — "11%" tells you to stop, but "4h1m" tells you when you can start
/// again — so as the percentage falls the emphasis deliberately moves to the time.
struct QuotaReadout: View {
    let meter: Meter?
    let usage: SubscriptionUsage?
    /// Set in the panel, where there is room for the account's name.
    var showsAccountLabel = false
    /// The left strip must read outward from the camera housing, so its visual
    /// order is the reverse of the right strip while keeping the logo nearest it.
    var mirrored = false
    var readsRightToLeft = false
    /// The compact closed strip is provider-specific: Claude shows five-hour
    /// quota, while Codex shows weekly quota. Expanded presentation opts into both.
    var showsFiveHour = true
    var showsWeek = true

    private var provider: Provider { meter?.provider ?? .claude }

    var body: some View {
        HStack(spacing: 7) {
            if mirrored {
                if showsWeek {
                    window(.week, reversed: readsRightToLeft)
                }
                if showsFiveHour {
                    if showsWeek { divider }
                    window(.fiveHour, reversed: readsRightToLeft)
                }
                identity
            } else {
                identity
                if showsFiveHour {
                    window(.fiveHour)
                }
                if showsWeek {
                    if showsFiveHour { divider }
                    window(.week)
                }
            }
        }
        // The strip is sized from this view's own fitting size, so it has to report
        // an honest ideal width rather than compressing into whatever it is given.
        .fixedSize()
        .help(tooltip)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private var identity: some View {
        if let meter {
            ProviderLogo(provider: meter.provider, size: NotchLayout.logoSize)
            if showsAccountLabel {
                Text(meter.displayLabel)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }
        }
    }

    private var divider: some View {
        Text("│")
            .font(.system(size: 9, weight: .regular))
            .foregroundStyle(.white.opacity(0.22))
    }

    @ViewBuilder
    private func window(_ window: QuotaWindow, reversed: Bool = false) -> some View {
        let remaining = usage?.remaining(in: window)
        let resetAt = usage?.resetAt(in: window)
        // Below ten per cent the percentage is dimmed and the countdown takes the
        // severity colour: at that point the reset time is the actionable half.
        let urgent = (remaining ?? 100) < 10
        let tone = QuotaTone.color(remaining: remaining, provider: provider)

        HStack(spacing: 4) {
            if reversed {
                if resetAt != nil { reset(resetAt, urgent: urgent, tone: tone) }
                percentage(remaining, urgent: urgent, tone: tone)
                period(window)
            } else {
                period(window)
                percentage(remaining, urgent: urgent, tone: tone)
                if resetAt != nil { reset(resetAt, urgent: urgent, tone: tone) }
            }
        }
    }

    private func period(_ window: QuotaWindow) -> some View {
        Text(window.shortTitle)
            .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
            .foregroundStyle(.white.opacity(0.4))
    }

    private func percentage(_ remaining: Double?, urgent: Bool, tone: Color) -> some View {
        Text(remaining.map { "\(Int($0.rounded()))%" } ?? "—")
            .font(.system(size: 9.5, weight: .bold, design: .monospaced))
            .foregroundStyle(urgent ? tone.opacity(0.55) : tone)
    }

    private func reset(_ resetAt: Date?, urgent: Bool, tone: Color) -> some View {
        Text(ResetCountdown.compact(resetAt))
            .font(.system(size: 9.5, weight: .bold, design: .monospaced))
            .foregroundStyle(urgent ? tone : .white.opacity(0.7))
    }

    private var tooltip: String {
        guard let meter else { return "No accounts configured" }
        let lines = QuotaWindow.allCases.compactMap { window -> String? in
            guard let value = usage?.remaining(in: window) else { return nil }
            let reset = ResetCountdown.absolute(usage?.resetAt(in: window))
            return "\(window.title): \(Int(value.rounded()))% left\(reset.map { ", resets \($0)" } ?? "")"
        }
        let name = "\(meter.displayLabel) (\(meter.provider.title))"
        guard !lines.isEmpty else { return "\(name) — no usage available" }
        return "\(name) — \(lines.joined(separator: " · "))"
    }

    private var accessibilityLabel: String {
        guard let meter else { return "No accounts configured" }
        return "\(meter.displayLabel) quota. \(tooltip)"
    }
}
