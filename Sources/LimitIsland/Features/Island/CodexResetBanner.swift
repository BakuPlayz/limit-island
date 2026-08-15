import AppKit
import SwiftUI

/// The one thing a high reset forecast is good for: knowing that tokens kept back
/// for later may not have a later.
///
/// It states the forecast, then the action, then the caveat — in that order and in
/// that hierarchy, so the hedge cannot be missed by reading only the bold line. The
/// site itself asks not to make spending decisions on it, and "looks likely" is as
/// far as a guess assembled from incidents and tweets is allowed to go here.
struct CodexResetBanner: View {
    let forecast: CodexResetForecast
    let onDismiss: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "bolt.fill")
                .islandFont(size: 12, weight: .semibold)
                .foregroundStyle(Provider.openAI.color)
                .padding(.leading, 2)

            VStack(alignment: .leading, spacing: 1) {
                Text("Codex reset looks likely — \(forecast.score)%")
                    .islandFont(size: 12, weight: .semibold)
                    .foregroundStyle(Provider.openAI.color)
                    .lineLimit(1)
                Text("Good time to spend tokens. It's a forecast, not a promise.")
                    .islandFont(size: 10.5)
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if let days = forecast.daysSinceReset {
                Text("\(days)d since last reset")
                    .islandFont(size: 9.5, weight: .medium)
                    .foregroundStyle(.white.opacity(0.45))
            }

            // Its own hit area rather than a button: the surrounding row opens the
            // site, and dismissing must not do both.
            Image(systemName: "xmark")
                .islandFont(size: 10, weight: .semibold)
                .foregroundStyle(.white.opacity(0.55))
                .padding(6)
                .contentShape(Rectangle())
                .onTapGesture(perform: onDismiss)
                .help("Hide this until the next reset")
        }
        .padding(.horizontal, 12)
        .frame(height: NotchLayout.rowHeight - 4)
        .frame(maxWidth: .infinity)
        .background(
            isHovered ? Color.white.opacity(0.14) : Color(red: 0.15, green: 0.16, blue: 0.18),
            in: RoundedRectangle(cornerRadius: 8)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Provider.openAI.color.opacity(0.35), lineWidth: 1)
        )
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture { NSWorkspace.shared.open(CodexResetStore.siteURL) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        // The score is a sum of published buckets, so show what it was made of
        // rather than asking anyone to take the number on faith.
        .help(helpText)
    }

    private var helpText: String {
        let source = "willcodexquotareset.com"
        guard !forecast.breakdown.isEmpty else { return source }
        return "\(forecast.breakdownSummary) · \(source)"
    }
}
