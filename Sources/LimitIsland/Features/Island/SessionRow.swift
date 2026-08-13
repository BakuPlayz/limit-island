import SwiftUI

/// The status dot: a session's state, readable without any text.
struct SessionDot: View {
    let session: AgentSession
    var size: CGFloat = NotchLayout.dotSize

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            // A session waiting on a person is the one thing here that is asking
            // for something, so it is the only one that moves.
            .modifier(BreathingHalo(active: session.activity.isWaiting, color: color, size: size))
            .help("\(session.title) — \(session.activity.detail ?? "Running")")
    }

    private var color: Color {
        switch session.activity {
        case .awaitingDecision, .waitingInTerminal: Color(red: 1.0, green: 0.72, blue: 0.28)
        case .done: Color(red: 0.36, green: 0.86, blue: 0.52)
        case .starting, .thinking, .running: session.provider.color
        }
    }
}

/// A slow pulse behind a dot that needs attention. Reduce Motion gets a static
/// halo instead — the dot must still stand out, just without moving.
private struct BreathingHalo: ViewModifier {
    let active: Bool
    let color: Color
    let size: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanded = false

    func body(content: Content) -> some View {
        content.background {
            if active {
                Circle()
                    .stroke(color.opacity(0.55), lineWidth: 1.5)
                    .frame(width: size * (expanded && !reduceMotion ? 2.2 : 1.7))
                    .opacity(expanded && !reduceMotion ? 0 : 0.9)
                    .animation(
                        reduceMotion ? nil : .easeOut(duration: 1.4).repeatForever(autoreverses: false),
                        value: expanded
                    )
                    // Driven by `active` rather than `.onAppear`: a re-render must
                    // not restart the pulse, or a row that redraws once a second
                    // never gets past the first frame of it.
                    .task(id: active) { expanded = true }
            }
        }
        .onChange(of: active) { _, isActive in
            if !isActive { expanded = false }
        }
    }
}

/// One session in the expanded panel.
struct SessionRow: View {
    let session: AgentSession
    let onJump: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 9) {
            SessionDot(session: session, size: 8)
                .padding(.leading, 2)

                VStack(alignment: .leading, spacing: 1) {
                    Text(session.title)
                        .islandFont(size: 12, weight: .semibold)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if let detail = session.activity.detail {
                        Text(detail)
                            .islandFont(size: 10.5)
                            .foregroundStyle(detailColor)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                badge(session.provider.title)
                if let terminal = session.terminal {
                    badge(terminal.displayName)
                }
                Text(session.elapsed)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.45))
                    .frame(width: 30, alignment: .trailing)
                Image(systemName: "arrow.up.forward.app")
                    .islandFont(size: 10, weight: .semibold)
                    .foregroundStyle(.white.opacity(0.55))
        }
        .padding(.horizontal, 12)
        // The card's outer vertical padding is part of the shared row budget.
        .frame(height: NotchLayout.rowHeight - 4)
        .frame(maxWidth: .infinity)
        .background(
            isHovered ? Color.white.opacity(0.14) : Color(red: 0.15, green: 0.16, blue: 0.18),
            in: RoundedRectangle(cornerRadius: 8)
        )
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        // Put the hit shape after padding so the complete visible row, including
        // its breathing room, navigates. A zero-distance DragGesture competed with
        // the surrounding ScrollView and often never delivered its mouse-up.
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture(perform: onJump)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onJump() }
        .help("Jump to this session in \(session.terminal?.displayName ?? "its terminal")")
    }

    private var detailColor: Color {
        switch session.activity {
        case .done: Color(red: 0.44, green: 0.86, blue: 0.55)
        case .awaitingDecision, .waitingInTerminal: Color(red: 1.0, green: 0.76, blue: 0.35)
        case .running: session.provider.color
        default: .white.opacity(0.55)
        }
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .islandFont(size: 9.5, weight: .medium)
            .foregroundStyle(.white.opacity(0.72))
            .padding(.horizontal, 6)
            .padding(.vertical, 2.5)
            .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 5))
    }
}
