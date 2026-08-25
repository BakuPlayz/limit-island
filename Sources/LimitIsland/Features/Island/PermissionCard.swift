import AppKit
import SwiftUI

/// The Allow/Deny card. What an agent is asking to do, and the two answers.
struct PermissionCard: View {
    let request: PendingRequest
    var queueCount = 1
    /// Project directory basename of the asking session — what a person recognises
    /// the agent by when several are running.
    var project: String? = nil
    let onAllow: () -> Void
    let onDeny: () -> Void
    var onAnswer: ([String: String]) -> Void = { _ in }
    var onApprovePlan: (Bool) -> Void = { _ in }
    var onRequestChanges: (String) -> Void = { _ in }
    var onJump: () -> Void = {}
    var onQuestionState: ((@escaping (Int) -> Void) -> Void)? = nil
    /// Raised while this card is showing a text field, so the window controller can
    /// lend the panel keyboard focus for exactly that long.
    var onComposing: (Bool) -> Void = { _ in }
    @State private var answerReady = false
    /// True while the plan card is collecting written feedback. The choices are
    /// replaced by the field rather than merely disabled, so there is nothing left
    /// on the card a keystroke could reach.
    @State private var isWritingFeedback = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ProviderLogo(provider: request.provider, size: 12)
                Text(headerTitle)
                    .islandFont(size: 10.5, weight: .medium)
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
                Spacer()
                if queueCount > 1 {
                    Text("1 of \(queueCount)")
                        .islandFont(size: 9.5, weight: .medium)
                        .foregroundStyle(.white.opacity(0.45))
                }
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
                    isEnabled: answerReady, onSubmit: onAnswer, onState: onQuestionState,
                    onComposing: onComposing
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

    /// Which agent is asking, not what it is asking: the project a person knows the
    /// session by, and only the provider's name when the session has no directory.
    private var headerTitle: String {
        guard let project, !project.isEmpty else { return request.provider.title }
        return project
    }

    private var humanAction: String {
        switch request.kind {
        case .edit: "Edit files"
        case .general: ToolSummary.activity(tool: request.tool, input: request.input)
        // Says who is asking as well as what for, so the plan card needs no second
        // header line under this one.
        case .plan: "\(request.provider.title) asks to review plan"
        case .question: "Question"
        }
    }

    /// Every plan choice at once, in the same numbered rows a question uses: how the
    /// agent should build is the decision, not a second screen behind "Build it".
    @ViewBuilder private func planControls(_ markdown: String) -> some View {
        // No header of its own: the row above already carries the icon, the agent's
        // name and what it is asking for, and repeating that cost a line of a card
        // that is mostly plan.
        VStack(alignment: .leading, spacing: 7) {
            if isWritingFeedback {
                InlineComposer(
                    prompt: "What should \(request.provider.title) change?",
                    placeholder: "Ask for a change",
                    accent: request.provider.color,
                    onSubmit: { feedback in
                        isWritingFeedback = false
                        onRequestChanges(feedback)
                    },
                    onCancel: { isWritingFeedback = false },
                    onComposing: onComposing,
                    emptySubmitTitle: "Keep planning"
                )
            } else {
            // The plan comes before the answers, and open: being told to read it is
            // the whole reason this card is on screen.
            if !markdown.isEmpty {
                ScrollView {
                    Text(PlanText.attributed(markdown)).islandFont(size: 11)
                        .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                }.frame(maxHeight: 210)
            }
            Text("Ready to build?")
                .islandFont(size: 13, weight: .medium)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(Array(planChoices(markdown).enumerated()), id: \.offset) { offset, choice in
                ChoiceRow(
                    number: offset + 1, label: choice.label, description: choice.description,
                    accent: request.provider.color, isEnabled: answerReady, action: choice.action
                )
            }
            }
        }
        .onAppear {
            onQuestionState? { option in
                let choices = planChoices(markdown)
                guard !isWritingFeedback, choices.indices.contains(option) else { return }
                choices[option].action()
            }
        }
    }

    private func planChoices(_ markdown: String) -> [PlanChoice] {
        [PlanChoice?]([
            PlanChoice(label: "Auto approve", description: "Edit files without asking again") {
                onApprovePlan(true)
            },
            PlanChoice(label: "Manual approve", description: "Ask before each edit") {
                onApprovePlan(false)
            },
            // A plan the hook did not carry is still readable — in the terminal that
            // wrote it. When it is on the card there is nothing to offer: the plan is
            // already open above these rows, and a row for closing it is one more
            // thing to read past on the way to the decision.
            markdown.isEmpty
                ? PlanChoice(label: "View plan", description: "Read it in the terminal", action: onJump)
                : nil,
            PlanChoice(label: "Request changes…", description: "Tell the agent what to fix") {
                isWritingFeedback = true
            }
        ]).compactMap { $0 }
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

/// A written answer, typed in the card.
///
/// This used to be an `NSAlert`. A modal system dialog in the middle of answering the
/// island was jarring, it blocked the app while it was up, and it never gave focus
/// back afterwards. The trade it does not avoid is the focus itself: macOS delivers
/// keystrokes to the active application, so `IslandWindowController.syncTextEntry`
/// takes focus while this is on screen and returns it on the way out — which is why
/// the appear/disappear signal matters more here than it looks.
/// A prompt, a field and two buttons. Shared by the permission card and the
/// auto-continue card so a typed answer looks and behaves the same wherever the
/// island asks for one.
struct InlineComposer: View {
    let prompt: String
    let placeholder: String
    let accent: Color
    let onSubmit: (String) -> Void
    let onCancel: () -> Void
    let onComposing: (Bool) -> Void
    /// When set, an empty field is itself an answer — "no, keep planning", with nothing
    /// to add — and the button says so rather than sitting disabled.
    var emptySubmitTitle: String? = nil

    @State private var text = ""
    @FocusState private var isFocused: Bool

    private var trimmed: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(prompt)
                .islandFont(size: 12, weight: .medium)
                .fixedSize(horizontal: false, vertical: true)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .islandFont(size: 12)
                .foregroundStyle(.white)
                .tint(accent)
                .padding(8)
                .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 7))
                .focused($isFocused)
                .onSubmit(send)
            HStack(spacing: 8) {
                AnswerButton(title: "Cancel", shortcut: "esc", emphasised: false, isEnabled: true, action: onCancel)
                AnswerButton(
                    title: trimmed.isEmpty ? (emptySubmitTitle ?? "Send") : "Send",
                    shortcut: "↩", emphasised: true,
                    isEnabled: !trimmed.isEmpty || emptySubmitTitle != nil, action: send
                )
            }
        }
        .onAppear {
            onComposing(true)
            isFocused = true
        }
        .onDisappear { onComposing(false) }
        .onExitCommand(perform: onCancel)
    }

    private func send() {
        guard !trimmed.isEmpty || emptySubmitTitle != nil else { return }
        onSubmit(trimmed)
    }
}

/// What a plan card offers, in the order the rows are numbered.
private struct PlanChoice {
    let label: String
    let description: String
    let action: () -> Void
}

/// One numbered choice. The same row whether an agent is asking a question, asking
/// how it should build a plan, or the island is asking which session to resume, so
/// every card reads as one thing.
struct ChoiceRow: View {
    /// Nil where no hotkey is bound to the row. The badge is a promise the panel
    /// only keeps while it holds the keyboard for an active card, and a shortcut
    /// printed on a row that does not answer to it is worse than no badge.
    var number: Int? = nil
    let label: String
    var description: String? = nil
    let accent: Color
    var isSelected = false
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        PressSurface(isEnabled: isEnabled, isSelected: isSelected, action: action) {
            HStack(alignment: .top, spacing: 9) {
                if let number {
                    Text("⌃⌘\(number)").islandFont(size: 9, weight: .semibold)
                        .padding(.horizontal, 5).padding(.vertical, 3)
                        .background(accent.opacity(0.18), in: RoundedRectangle(cornerRadius: 5))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(label).islandFont(size: 12, weight: .medium)
                        .fixedSize(horizontal: false, vertical: true)
                    if let description {
                        Text(description).islandFont(size: 9.5).opacity(0.58)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 4)
                if isSelected { Image(systemName: "checkmark").foregroundStyle(accent) }
            }
            .padding(8)
        }
    }
}

private struct QuestionChoices: View {
    let question: AgentQuestion
    let provider: Provider
    let isEnabled: Bool
    let onSubmit: ([String: String]) -> Void
    let onState: ((@escaping (Int) -> Void) -> Void)?
    let onComposing: (Bool) -> Void
    @State private var index = 0
    @State private var selected: Set<String> = []
    @State private var answers: [String: String] = [:]
    /// What was ticked on each question already passed, so stepping back shows the
    /// earlier answer to change rather than an empty list.
    @State private var selections: [Int: Set<String>] = [:]
    /// The options are replaced by the field while a written answer is being typed,
    /// so nothing else on the card is reachable in the moment the panel holds focus.
    @State private var isWritingAnswer = false

    var body: some View {
        let item = question.items[index]
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: "message.fill")
                Text("\(provider.title) asks").fontWeight(.semibold)
                Spacer()
                if index > 0 {
                    PressSurface(expands: false, action: goBack) {
                        HStack(spacing: 3) {
                            Image(systemName: "chevron.left")
                            Text("Back")
                        }
                        .islandFont(size: 9.5, weight: .medium)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                    }
                }
                if question.items.count > 1 { Text("\(index + 1) of \(question.items.count)") }
            }
            .islandFont(size: 10.5, weight: .medium)
            .foregroundStyle(provider.color)
            Text(item.question)
                .islandFont(size: 13, weight: .medium)
                .fixedSize(horizontal: false, vertical: true)
            // A question with no options at all — which Codex is allowed to ask —
            // has nothing to pick, so the field is the card rather than something
            // reached by way of an "Other…" row.
            if isWritingAnswer || item.isFreeTextOnly {
                InlineComposer(
                    prompt: item.header,
                    placeholder: "Type your answer",
                    accent: provider.color,
                    onSubmit: { answer in
                        isWritingAnswer = false
                        answerOther(answer, for: item)
                    },
                    onCancel: { isWritingAnswer = false },
                    onComposing: onComposing
                )
            } else {
            ForEach(Array(item.options.enumerated()), id: \.element.id) { offset, option in
                optionRow(option, number: offset + 1, item: item)
            }
            PressSurface(isEnabled: isEnabled, action: { isWritingAnswer = true }) {
                HStack(spacing: 9) {
                    Image(systemName: "ellipsis.bubble")
                    Text("Other…").islandFont(size: 12, weight: .medium)
                    Spacer()
                }
                .padding(8)
            }
            if item.multiSelect {
                PressSurface(
                    isEnabled: isEnabled && !selected.isEmpty,
                    fill: provider.color,
                    action: { advance(item) }
                ) {
                    Text("Continue")
                        .islandFont(size: 12, weight: .semibold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .foregroundStyle(.black)
                }
            }
            }
        }
        .onAppear { publish(item) }
        .onChange(of: index) { _, _ in publish(question.items[index]) }
    }

    private func optionRow(_ option: AgentQuestion.Item.Option, number: Int, item: AgentQuestion.Item) -> some View {
        let chosen = selected.contains(option.label)
        return ChoiceRow(
            number: number, label: option.label, description: option.description,
            accent: provider.color, isSelected: chosen, isEnabled: isEnabled
        ) {
            if item.multiSelect {
                if chosen { selected.remove(option.label) } else { selected.insert(option.label) }
            } else {
                selected = [option.label]
                advance(item)
            }
        }
    }

    private func advance(_ item: AgentQuestion.Item) {
        guard !selected.isEmpty else { return }
        answers[item.question] = selected.sorted().joined(separator: ", ")
        selections[index] = selected
        selected.removeAll()
        if index + 1 < question.items.count { index += 1 } else { onSubmit(answers) }
    }

    /// Nothing has been sent to the agent until the last question is answered, so
    /// an earlier answer is still the person's to change.
    private func goBack() {
        guard index > 0 else { return }
        selections[index] = selected
        index -= 1
        selected = selections[index] ?? []
    }

    private func publish(_ item: AgentQuestion.Item) {
        onState? { option in
            guard !isWritingAnswer, item.options.indices.contains(option) else { return }
            let label = item.options[option].label
            if item.multiSelect {
                if selected.contains(label) { selected.remove(label) } else { selected.insert(label) }
            } else {
                selected = [label]
                advance(item)
            }
        }
    }

    /// A written answer counts as this question answered, exactly as picking an
    /// option does, so it moves the stepper along the same way.
    private func answerOther(_ text: String, for item: AgentQuestion.Item) {
        answers[item.question] = text
        selections[index] = []
        selected.removeAll()
        if index + 1 < question.items.count { index += 1 } else { onSubmit(answers) }
    }
}

struct CodexQuestionCard: View {
    let question: AgentQuestion
    var queueCount = 1
    /// Returns true only when the selection was delivered to the exact terminal.
    let onSelection: ([Int], Bool) async -> Bool
    let onFinished: () -> Void
    let onFallback: () -> Void
    let onQuestionState: ((@escaping (Int) -> Void) -> Void)?
    var onComposing: (Bool) -> Void = { _ in }
    @State private var index = 0
    @State private var selected: Set<Int> = []

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
                    PressSurface(
                        isEnabled: !selected.isEmpty,
                        fill: Provider.openAI.color,
                        action: { submit(item) }
                    ) {
                        Text("Continue")
                            .islandFont(size: 12, weight: .semibold)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7)
                            .foregroundStyle(.black)
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
        Task { @MainActor in
            guard await onSelection(choices, item.multiSelect) else {
                // Bring the exact picker forward for direct input. Its transcript will
                // clear this card as soon as the terminal accepts the answer.
                onFallback()
                return
            }
            selected.removeAll()
            if index + 1 < question.items.count { index += 1 } else { onFinished() }
        }
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
    /// A solid colour for a primary action. Without it the surface is the faint
    /// translucent white the option rows use, which dark label text disappears into.
    var fill: Color? = nil
    /// False for a control that should be only as wide as its label, such as the
    /// Back pill in a question header.
    var expands = true
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @State private var isPressed = false
    @State private var isHovered = false

    var body: some View {
        label()
        .frame(maxWidth: expands ? .infinity : nil, alignment: .leading)
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
        if let fill {
            if isPressed { return fill.opacity(0.7) }
            return isHovered && isEnabled ? fill : fill.opacity(0.9)
        }
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
