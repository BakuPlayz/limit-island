import AppKit
import SwiftUI

/// The Allow/Deny card. What an agent is asking to do, and the two answers.
struct PermissionCard: View {
    let request: PendingRequest
    var queueCount = 1
    let onAllow: () -> Void
    let onDeny: () -> Void
    var onAnswer: ([String: String]) -> Void = { _ in }
    var onApprovePlan: (Bool) -> Void = { _ in }
    var onRequestChanges: (String) -> Void = { _ in }
    var onJump: () -> Void = {}
    var onQuestionState: ((Int, AgentQuestion.Item, @escaping (Int) -> Void) -> Void)? = nil
    @State private var answerReady = false
    @State private var planStage = 0 // summary, preview, build mode

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle()
                    .fill(Color(red: 1.0, green: 0.62, blue: 0.25))
                    .frame(width: 6, height: 6)
                Text(cardTitle)
                    .islandFont(size: 10.5, weight: .medium)
                    .foregroundStyle(.white.opacity(0.6))
                Spacer()
                if queueCount > 1 {
                    Text("1 of \(queueCount)")
                        .islandFont(size: 9.5, weight: .medium)
                        .foregroundStyle(.white.opacity(0.45))
                }
                Text(request.provider.title)
                    .islandFont(size: 9.5, weight: .medium)
                    .foregroundStyle(.white.opacity(0.45))
            }

            if case .question = request.kind { EmptyView() } else { HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Color(red: 1.0, green: 0.66, blue: 0.3))
                Text(humanAction)
                    .islandFont(size: 13, weight: .bold)
                    .foregroundStyle(Color(red: 1.0, green: 0.66, blue: 0.3))
                if let target = request.target {
                    Text(target)
                        .font(.system(size: 13, weight: .regular, design: .monospaced))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            } }

            body(for: request.kind)

            if case let .question(question) = request.kind, let question {
                QuestionChoices(
                    question: question, provider: request.provider,
                    isEnabled: answerReady, onSubmit: onAnswer, onState: onQuestionState
                )
            } else if case let .plan(markdown) = request.kind {
                planControls(markdown)
            } else { HStack(spacing: 8) {
                // ⌃⌘, not ⌘: these are read by a global monitor, and plain ⌘Y/⌘N
                // are Redo and New in other apps — a stray press must not answer a
                // permission request nobody read.
                answerButton("Deny", shortcut: "⌃⌘N", emphasised: false, action: onDeny)
                answerButton("Allow", shortcut: "⌃⌘Y", emphasised: true, action: onAllow)
            } }

            PressSurface(action: onJump) {
                Label("Open in terminal", systemImage: "arrow.up.forward.app")
                    .islandFont(size: 10, weight: .medium)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
            }
        }
        .padding(12)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
        .task(id: request.id) {
            answerReady = false
            let elapsed = Date.now.timeIntervalSince(request.receivedAt)
            let remaining = max(0, PendingRequest.minimumDeliberationTime - elapsed)
            if remaining > 0 { try? await Task.sleep(for: .seconds(remaining)) }
            guard !Task.isCancelled else { return }
            answerReady = true
        }
    }

    private var cardTitle: String {
        switch request.kind {
        case .question: "\(request.provider.title) asks"
        case .plan: "Plan ready"
        case .edit: "Review changes"
        case .general: "Approval needed"
        }
    }

    private var humanAction: String {
        switch request.kind {
        case .edit: "Edit files"
        case .general: ToolSummary.activity(tool: request.tool, input: request.input)
        case .plan: "Review the plan"
        case .question: "Question"
        }
    }

    @ViewBuilder private func planControls(_ markdown: String) -> some View {
        if planStage == 1 {
            ScrollView {
                Text(PlanText.attributed(markdown)).islandFont(size: 11)
                    .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            }.frame(maxHeight: 210)
        } else {
            Text(planStage == 2 ? "How should \(request.provider.title) build it?" : "Review the plan, request changes, or start building.")
                .islandFont(size: 12).foregroundStyle(.white.opacity(0.82))
        }
        if planStage == 2 {
            HStack(spacing: 8) {
                answerButton("Back", shortcut: "", emphasised: false) { planStage = 0 }
                answerButton("Manual approve", shortcut: "", emphasised: false) { onApprovePlan(false) }
                answerButton("Auto approve", shortcut: "", emphasised: true) { onApprovePlan(true) }
            }
        } else {
            HStack(spacing: 8) {
                answerButton("Deny", shortcut: "", emphasised: false) {
                    guard let feedback = textPrompt(title: "Ask for plan changes", question: "What should the agent change?") else { return }
                    onRequestChanges(feedback)
                }
                answerButton("Build it", shortcut: "", emphasised: true) { planStage = 2 }
                answerButton(planStage == 1 ? "Hide plan" : "See plan", shortcut: "", emphasised: false) { planStage = planStage == 1 ? 0 : 1 }
            }
        }
    }

    private func textPrompt(title: String, question: String) -> String? {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = question
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24)); alert.accessoryView = field
        alert.addButton(withTitle: "Submit"); alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    @ViewBuilder
    private func body(for kind: PendingRequest.Kind) -> some View {
        switch kind {
        case .question:
            EmptyView()
        case .edit:
            DiffView(
                old: request.input?.string("old_string") ?? "",
                new: request.input?.string("new_string") ?? request.input?.string("content") ?? ""
            )
        case .plan:
            EmptyView()
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
        AnswerButton(
            title: title, shortcut: shortcut, emphasised: emphasised,
            isEnabled: answerReady, action: action
        )
    }
}

private struct QuestionChoices: View {
    let question: AgentQuestion
    let provider: Provider
    let isEnabled: Bool
    let onSubmit: ([String: String]) -> Void
    let onState: ((Int, AgentQuestion.Item, @escaping (Int) -> Void) -> Void)?
    @State private var index = 0
    @State private var selected: Set<String> = []
    @State private var answers: [String: String] = [:]

    var body: some View {
        let item = question.items[index]
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Image(systemName: "message.fill")
                Text("\(provider.title) asks").fontWeight(.semibold)
                Spacer()
                if question.items.count > 1 { Text("\(index + 1) of \(question.items.count)") }
            }
            .islandFont(size: 10.5, weight: .medium)
            .foregroundStyle(provider.color)
            Text(item.question)
                .islandFont(size: 13, weight: .medium)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(Array(item.options.enumerated()), id: \.element.id) { offset, option in
                optionRow(option, number: offset + 1, item: item)
            }
            PressSurface(isEnabled: isEnabled, action: { collectOther(for: item) }) {
                HStack(spacing: 9) {
                    Image(systemName: "ellipsis.bubble")
                    Text("Other…").islandFont(size: 12, weight: .medium)
                    Spacer()
                }
                .padding(8)
            }
            if item.multiSelect {
                PressSurface(isEnabled: isEnabled && !selected.isEmpty, action: { advance(item) }) {
                    Text("Continue")
                        .islandFont(size: 12, weight: .semibold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .foregroundStyle(.black)
                }
                .tint(provider.color)
            }
        }
        .onAppear { publish(item) }
        .onChange(of: index) { _, _ in publish(question.items[index]) }
    }

    private func optionRow(_ option: AgentQuestion.Item.Option, number: Int, item: AgentQuestion.Item) -> some View {
        let chosen = selected.contains(option.label)
        return PressSurface(isEnabled: isEnabled, isSelected: chosen, action: {
            if item.multiSelect {
                if chosen { selected.remove(option.label) } else { selected.insert(option.label) }
            } else {
                selected = [option.label]
                advance(item)
            }
        }) {
            HStack(alignment: .top, spacing: 9) {
                Text("⌃⌘\(number)").islandFont(size: 9, weight: .semibold)
                    .padding(.horizontal, 5).padding(.vertical, 3)
                    .background(provider.color.opacity(0.18), in: RoundedRectangle(cornerRadius: 5))
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label).islandFont(size: 12, weight: .medium)
                        .fixedSize(horizontal: false, vertical: true)
                    if let description = option.description {
                        Text(description).islandFont(size: 9.5).opacity(0.58)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 4)
                if chosen { Image(systemName: "checkmark").foregroundStyle(provider.color) }
            }
            .padding(8)
        }
    }

    private func advance(_ item: AgentQuestion.Item) {
        guard !selected.isEmpty else { return }
        answers[item.question] = selected.sorted().joined(separator: ", ")
        selected.removeAll()
        if index + 1 < question.items.count { index += 1 } else { onSubmit(answers) }
    }

    private func publish(_ item: AgentQuestion.Item) {
        onState?(index, item) { option in
            guard item.options.indices.contains(option) else { return }
            let label = item.options[option].label
            if item.multiSelect {
                if selected.contains(label) { selected.remove(label) } else { selected.insert(label) }
            } else {
                selected = [label]
                advance(item)
            }
        }
    }

    private func collectOther(for item: AgentQuestion.Item) {
        let alert = NSAlert()
        alert.messageText = item.header
        alert.informativeText = item.question
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "Type your answer"
        alert.accessoryView = field
        alert.addButton(withTitle: "Submit")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        answers[item.question] = text
        if index + 1 < question.items.count { index += 1 } else { onSubmit(answers) }
    }
}

struct CodexQuestionCard: View {
    let question: AgentQuestion
    var queueCount = 1
    /// Returns true only when the selection was delivered to the exact terminal.
    let onSelection: ([Int], Bool) -> Bool
    let onFinished: () -> Void
    let onFallback: () -> Void
    let onQuestionState: ((@escaping (Int) -> Void) -> Void)?
    @State private var index = 0
    @State private var selected: Set<Int> = []
    @State private var planStage = 0

    var body: some View {
        if question.items.indices.contains(index) {
            let item = question.items[index]
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Label("Codex asks", systemImage: "message.fill")
                    Spacer()
                    if question.items.count > 1 { Text("Question \(index + 1) of \(question.items.count)") }
                    if queueCount > 1 { Text("· 1 of \(queueCount) agents") }
                }
                .islandFont(size: 10.5, weight: .semibold)
                .foregroundStyle(Provider.openAI.color)

                Text(item.question)
                    .islandFont(size: 13, weight: .medium)
                    .fixedSize(horizontal: false, vertical: true)

                if isPlanExit(item) {
                    if planStage == 0 {
                        HStack(spacing: 8) {
                            codexAction("Deny", false) { choose(planOption(containing: "change", in: item) ?? 2, item: item) }
                            codexAction("Build it", true) { planStage = 1 }
                            codexAction("See plan", false, action: onFallback)
                        }
                    } else {
                        HStack(spacing: 8) {
                            codexAction("Back", false) { planStage = 0 }
                            codexAction("Manual approve", false) { choose(planOption(containing: "manual", in: item) ?? 1, item: item) }
                            codexAction("Auto approve", true) { choose(planOption(containing: "auto", in: item) ?? 0, item: item) }
                        }
                    }
                } else {

                ForEach(Array(item.options.enumerated()), id: \.offset) { optionIndex, option in
                    PressSurface(isSelected: selected.contains(optionIndex), action: {
                        choose(optionIndex, item: item)
                    }) {
                        HStack(alignment: .top, spacing: 9) {
                            Text("⌃⌘\(optionIndex + 1)").islandFont(size: 9, weight: .semibold)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(option.label).islandFont(size: 12, weight: .medium)
                                    .fixedSize(horizontal: false, vertical: true)
                                if let description = option.description {
                                    Text(description).islandFont(size: 9.5).opacity(0.58)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            Spacer(minLength: 4)
                            if selected.contains(optionIndex) {
                                Image(systemName: "checkmark").foregroundStyle(Provider.openAI.color)
                            }
                        }
                        .padding(8)
                    }
                }

                if item.multiSelect {
                    PressSurface(isEnabled: !selected.isEmpty, action: { submit(item) }) {
                        Text("Continue")
                            .islandFont(size: 12, weight: .semibold)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7)
                            .foregroundStyle(.black)
                    }
                    .tint(Provider.openAI.color)
                }
                }

                PressSurface(action: onFallback) {
                    Label("Answer in terminal", systemImage: "arrow.up.forward.app")
                        .islandFont(size: 10, weight: .medium)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                }
            }
            .padding(12).background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
            .onAppear { publish(item) }
            .onChange(of: index) { _, newIndex in
                guard question.items.indices.contains(newIndex) else { return }
                publish(question.items[newIndex])
            }
        }
    }

    private func isPlanExit(_ item: AgentQuestion.Item) -> Bool {
        item.options.contains { $0.label.localizedCaseInsensitiveContains("auto mode") } &&
        item.options.contains { $0.label.localizedCaseInsensitiveContains("manual") }
    }

    private func planOption(containing text: String, in item: AgentQuestion.Item) -> Int? {
        item.options.firstIndex { $0.label.localizedCaseInsensitiveContains(text) }
    }

    private func codexAction(_ title: String, _ primary: Bool, action: @escaping () -> Void) -> some View {
        AnswerButton(title: title, shortcut: "", emphasised: primary, isEnabled: true, action: action)
    }

    private func choose(_ option: Int, item: AgentQuestion.Item) {
        if item.multiSelect {
            if selected.contains(option) { selected.remove(option) } else { selected.insert(option) }
        } else {
            selected = [option]
            submit(item)
        }
    }

    private func submit(_ item: AgentQuestion.Item) {
        guard !selected.isEmpty else { return }
        let choices = selected.sorted()
        guard onSelection(choices, item.multiSelect) else {
            // Bring the exact picker forward for direct input. Its transcript will
            // clear this card as soon as the terminal accepts the answer.
            onFallback()
            return
        }
        selected.removeAll()
        if index + 1 < question.items.count { index += 1 } else { onFinished() }
    }

    private func publish(_ item: AgentQuestion.Item) {
        onQuestionState? { option in
            guard item.options.indices.contains(option) else { return }
            choose(option, item: item)
        }
    }
}

/// A mouse-only control for the non-activating panel. It deliberately does not use
/// `Button`, so Return/Space in the editor cannot trigger it, but still requires a
/// complete press and release inside the visible control.
private struct PressSurface<Label: View>: View {
    var isEnabled = true
    var isSelected = false
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @State private var isPressed = false
    @State private var isHovered = false

    var body: some View {
        label()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background, in: RoundedRectangle(cornerRadius: 7))
        .contentShape(RoundedRectangle(cornerRadius: 7))
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = isEnabled }
                .onEnded { value in
                    isPressed = false
                    guard isEnabled,
                          value.translation.width.magnitude < 24,
                          value.translation.height.magnitude < 24 else { return }
                    action()
                }
        )
        .onHover { isHovered = $0 }
        .opacity(isEnabled ? 1 : 0.45)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { if isEnabled { action() } }
    }

    private var background: Color {
        if isPressed { return Color.accentColor.opacity(0.55) }
        if isSelected { return Color.accentColor.opacity(0.25) }
        if isHovered && isEnabled { return .white.opacity(0.14) }
        return .white.opacity(0.07)
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
    let isEnabled: Bool
    let action: () -> Void

    @State private var isPressed = false
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 5) {
            Text(title)
                .islandFont(size: 12, weight: .semibold)
            Text(shortcut)
                .islandFont(size: 9.5, weight: .medium)
                .opacity(0.55)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 7)
        .background(background, in: RoundedRectangle(cornerRadius: 7))
        .foregroundStyle(emphasised ? Color.black : Color.white)
        .opacity(isEnabled ? 1 : 0.48)
        .contentShape(RoundedRectangle(cornerRadius: 7))
        .onHover { isHovered = $0 }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { value in
                    isPressed = false
                    // Released outside the control is a cancelled press, exactly as
                    // a real button behaves.
                    guard isEnabled,
                          value.translation.width.magnitude < 40,
                          value.translation.height.magnitude < 40 else { return }
                    action()
                }
        )
        .accessibilityElement()
        .accessibilityLabel(title)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { if isEnabled { action() } }
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
        // Keep the decision controls visible without losing access to a long diff.
        // The diff owns this compact scroll viewport; the card's actions remain
        // immediately below it instead of being pushed off the panel.
        .frame(maxHeight: 82)
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
