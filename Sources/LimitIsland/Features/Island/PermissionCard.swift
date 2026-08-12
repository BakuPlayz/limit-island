import SwiftUI

/// The Allow/Deny card. What an agent is asking to do, and the two answers.
struct PermissionCard: View {
    let request: PendingRequest
    let onAllow: () -> Void
    let onDeny: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle()
                    .fill(Color(red: 1.0, green: 0.62, blue: 0.25))
                    .frame(width: 6, height: 6)
                Text("Permission Request")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                Spacer()
                Text(request.provider.title)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45))
            }

            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Color(red: 1.0, green: 0.66, blue: 0.3))
                Text(request.tool)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color(red: 1.0, green: 0.66, blue: 0.3))
                if let target = request.target {
                    Text(target)
                        .font(.system(size: 13, weight: .regular, design: .monospaced))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            body(for: request.kind)

            HStack(spacing: 8) {
                // ⌃⌘, not ⌘: these are read by a global monitor, and plain ⌘Y/⌘N
                // are Redo and New in other apps — a stray press must not answer a
                // permission request nobody read.
                answerButton("Deny", shortcut: "⌃⌘N", emphasised: false, action: onDeny)
                answerButton("Allow", shortcut: "⌃⌘Y", emphasised: true, action: onAllow)
            }
        }
        .padding(12)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func body(for kind: PendingRequest.Kind) -> some View {
        switch kind {
        case .edit:
            DiffView(
                old: request.input?.string("old_string") ?? "",
                new: request.input?.string("new_string") ?? request.input?.string("content") ?? ""
            )
        case let .plan(markdown):
            ScrollView {
                Text(PlanText.attributed(markdown))
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 150)
        case .general:
            if let command = ToolSummary.command(request.input) {
                ScrollView {
                    Text(command)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.9))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 90)
                .padding(8)
                .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    private func answerButton(
        _ title: String,
        shortcut: String,
        emphasised: Bool,
        action: @escaping () -> Void
    ) -> some View {
        AnswerButton(title: title, shortcut: shortcut, emphasised: emphasised, action: action)
    }
}

/// Allow and Deny, deliberately not a `Button`.
///
/// A card once answered itself with the pointer parked in the opposite corner of the
/// screen: the log showed the `Button`'s own action firing with nothing to fire it.
/// A press gesture requires a pointer-down inside the control followed by a release
/// inside it, which no focus ring, key equivalent or replayed action can stand in
/// for. `PendingRequest` also refuses anything answered faster than a person could
/// read it, so this is the first of two independent guards rather than the only one.
private struct AnswerButton: View {
    let title: String
    let shortcut: String
    let emphasised: Bool
    let action: () -> Void

    @State private var isPressed = false
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 5) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
            Text(shortcut)
                .font(.system(size: 9.5, weight: .medium))
                .opacity(0.55)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 7)
        .background(background, in: RoundedRectangle(cornerRadius: 7))
        .foregroundStyle(emphasised ? Color.black : Color.white)
        .contentShape(RoundedRectangle(cornerRadius: 7))
        .onHover { isHovered = $0 }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { value in
                    isPressed = false
                    // Released outside the control is a cancelled press, exactly as
                    // a real button behaves.
                    guard value.translation.width.magnitude < 40,
                          value.translation.height.magnitude < 40 else { return }
                    action()
                }
        )
        .accessibilityElement()
        .accessibilityLabel(title)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { action() }
    }

    private var background: Color {
        let base = emphasised ? Color.white.opacity(0.92) : Color.white.opacity(0.12)
        if isPressed { return emphasised ? .white.opacity(0.7) : .white.opacity(0.24) }
        if isHovered { return emphasised ? .white : .white.opacity(0.18) }
        return base
    }
}

/// A line-level view of an edit.
///
/// Not a real diff algorithm: the tool input already gives us exactly the text
/// being replaced and the text replacing it, so the removed and added blocks are
/// known outright. Running an LCS over them would only re-derive what we were told,
/// and would occasionally disagree with what the agent actually does.
struct DiffView: View {
    let old: String
    let new: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    HStack(alignment: .top, spacing: 6) {
                        Text(line.marker)
                            .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                            .foregroundStyle(line.color)
                            .frame(width: 8, alignment: .leading)
                        Text(line.text.isEmpty ? " " : line.text)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(line.color)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(line.background)
                }
            }
            .padding(.vertical, 4)
        }
        .frame(maxHeight: 140)
        .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 6))
        .overlay(alignment: .bottomTrailing) {
            Text("+\(added) −\(removed)")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.45))
                .padding(5)
        }
    }

    private struct Line {
        let marker: String
        let text: String
        let color: Color
        let background: Color
    }

    private var removedLines: [String] { old.isEmpty ? [] : old.components(separatedBy: "\n") }
    private var addedLines: [String] { new.isEmpty ? [] : new.components(separatedBy: "\n") }
    private var removed: Int { removedLines.count }
    private var added: Int { addedLines.count }

    private var lines: [Line] {
        removedLines.map {
            Line(
                marker: "−",
                text: $0,
                color: Color(red: 1.0, green: 0.55, blue: 0.52),
                background: Color(red: 0.4, green: 0.1, blue: 0.1).opacity(0.4)
            )
        }
        + addedLines.map {
            Line(
                marker: "+",
                text: $0,
                color: Color(red: 0.55, green: 0.92, blue: 0.6),
                background: Color(red: 0.1, green: 0.32, blue: 0.14).opacity(0.4)
            )
        }
    }
}

enum PlanText {
    /// Plans arrive as Markdown. `AttributedString`'s parser handles the inline
    /// marks; block structure is left as written, which reads correctly because
    /// plans are mostly lists and short paragraphs.
    static func attributed(_ markdown: String) -> AttributedString {
        (try? AttributedString(
            markdown: markdown,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(markdown)
    }
}
