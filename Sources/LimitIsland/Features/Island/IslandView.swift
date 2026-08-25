import SwiftUI

/// Metrics shared by the resting strip and the expanded panel.
enum NotchLayout {
    /// Clearance between the strip's content and the camera housing.
    static let notchInset: CGFloat = 10
    static let outerEdgePadding: CGFloat = 8
    static let dotSize: CGFloat = 7
    static let dotSpacing: CGFloat = 5
    static let logoSize: CGFloat = 13
    /// Each pinned account owns a stable side of the closed notch. Keeping this
    /// fixed prevents a countdown or percentage digit from moving the whole bar.
    static let pinnedSlotWidth: CGFloat = 124

    /// The expanded panel is a fixed width rather than a fraction of the display:
    /// it holds one line of prose per session, and a line that grows with a 6K
    /// monitor is harder to read, not easier.
    static let panelWidth: CGFloat = 520
    static let panelCornerRadius: CGFloat = 14
    static let rowHeight: CGFloat = 46
    /// Floor for the panel's top band. The real height comes from the display's
    /// camera housing, which is taller than this on most Macs.
    static let minimumHeaderHeight: CGFloat = 30
    /// Ceiling on the expanded height, after which the session list scrolls. Tall
    /// enough for the worst card there is — a plan with its Markdown open and a text
    /// field under it — because a field that scrolls out of view while it holds the
    /// keyboard is worse than a taller panel.
    static let maximumPanelHeight: CGFloat = 520

    /// Measures a view at its ideal size, off-screen.
    ///
    /// The strip is sized to its content, and the window frame and the content have
    /// to agree about that size exactly — when they disagreed, the `HStack`
    /// overflowed, the notch spacer collapsed to its minimum, and the quota readout
    /// slid under the camera housing.
    ///
    /// So the ruler is the view itself rather than an `NSFont` measurement of a
    /// sample string: `QuotaReadout` mixes three type sizes, a bundled logo and two
    /// spacings, and any independent estimate of that drifts the moment the view
    /// changes. Measuring what is actually rendered cannot drift.
    @MainActor
    static func measuredWidth(of view: some View) -> CGFloat {
        let ruler = NSHostingView(rootView: view)
        // Let it choose its own size in both axes rather than inheriting a width.
        ruler.frame = .zero
        return ceil(ruler.fittingSize.width)
    }

    /// Total strip width for a measured content width, including the clearance
    /// beside the housing and the padding at the screen edge.
    static func sideWidth(contentWidth: CGFloat) -> CGFloat {
        guard contentWidth > 0 else { return 0 }
        return contentWidth + notchInset + outerEdgePadding
    }

    static func dotsWidth(count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        let dots = CGFloat(count) * dotSize + CGFloat(count - 1) * dotSpacing
        return sideWidth(contentWidth: dots)
    }

    /// Expanded height below the top band, for a given number of sessions and cards.
    static func panelHeight(
        sessions: Int, cards: Int, headerHeight: CGFloat, cardHeight: CGFloat? = nil
    ) -> CGFloat {
        // Interaction mode hides the session list, so its size must not grow with
        // the number of rows sitting behind the active card.
        let rows = cards > 0 ? 0 : CGFloat(max(sessions, 1)) * rowHeight + 16
        // Start at a useful card size, then follow SwiftUI's actual measurement.
        // Exceptionally long cards stop at the ceiling and scroll.
        let cardSpace = cards > 0 ? max(180, cardHeight ?? 260) : 0
        return min(maximumPanelHeight - headerHeight, rows + cardSpace)
    }
}

/// Which reset window a readout is reporting on.
enum QuotaWindow: CaseIterable {
    case fiveHour
    case week

    /// The label in the strip: `5h`, `7d`.
    var shortTitle: String {
        switch self {
        case .fiveHour: "5h"
        case .week: "7d"
        }
    }

    var title: String {
        switch self {
        case .fiveHour: "five-hour"
        case .week: "weekly"
        }
    }

    var other: QuotaWindow { self == .fiveHour ? .week : .fiveHour }
}

enum ResetCountdown {
    /// The strip's form: coarse when the reset is days out, precise as it nears.
    /// Hours carry their minutes (`4h1m`) because "4h" and "4h59m" are the
    /// difference between waiting and going to lunch.
    static func compact(_ resetAt: Date?) -> String {
        guard let resetAt else { return "—" }
        let seconds = max(0, Int(resetAt.timeIntervalSinceNow.rounded(.down)))
        if seconds >= 86_400 {
            let days = seconds / 86_400
            let hours = (seconds % 86_400) / 3_600
            // Past a week the extra hours stop being informative and start costing
            // characters the strip does not have, so they are dropped there.
            guard days < 10, hours > 0 else { return "\(days)d" }
            return "\(days)d\(hours)h"
        }
        if seconds >= 3_600 {
            let hours = seconds / 3_600
            let minutes = (seconds % 3_600) / 60
            return minutes > 0 ? "\(hours)h\(minutes)m" : "\(hours)h"
        }
        if seconds >= 60 { return "\(seconds / 60)m" }
        return "<1m"
    }

    /// Full wall-clock reset for a tooltip, dated only when it is not today.
    static func absolute(_ resetAt: Date?) -> String? {
        guard let resetAt else { return nil }
        let time = resetAt.formatted(date: .omitted, time: .shortened)
        guard !Calendar.current.isDateInToday(resetAt) else { return time }
        return "\(resetAt.formatted(.dateTime.weekday(.abbreviated))) \(time)"
    }

    /// Full local date and time for Settings, where a reset schedule is a
    /// reference rather than a glanceable countdown.
    static func settings(_ resetAt: Date?) -> String? {
        resetAt?.formatted(date: .abbreviated, time: .shortened)
    }
}

/// Severity shading, shared by the quota readout and the session dots.
enum QuotaTone {
    static func color(remaining: Double?, provider: Provider) -> Color {
        guard let remaining else { return .white.opacity(0.5) }
        if remaining < 10 { return Color(red: 1.0, green: 0.42, blue: 0.38) }
        if remaining < 50 { return Color(red: 1.0, green: 0.79, blue: 0.35) }
        return provider.color
    }
}
