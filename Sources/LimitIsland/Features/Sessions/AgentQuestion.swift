import Foundation

/// A question an agent is holding for, in the one shape the island renders.
///
/// Two CLIs feed this and they do not agree on much. Claude's `AskUserQuestion`
/// keys its answers by the question's *text* and always ships options. Codex's
/// `request_user_input` keys them by an `id` it generates, allows free text, and
/// treats `options` as optional — a question with none is free text only. The
/// fields below are the union, and `key` is the seam: whatever the agent wants its
/// answer filed under.
struct AgentQuestion: Equatable, Sendable {
    struct Item: Equatable, Sendable, Identifiable {
        struct Option: Equatable, Sendable, Identifiable {
            let label: String
            let description: String?
            var id: String { label }
        }

        /// What the agent expects its answer filed under. Codex generates an `id`
        /// and reads it back; Claude has none, so its own key — the question text —
        /// stands in.
        let key: String
        let question: String
        let header: String
        let options: [Option]
        let multiSelect: Bool
        /// Free text is an acceptable answer, not only one of the options.
        let allowsOther: Bool
        /// The answer is a credential. It must not be typed into the panel or put in
        /// a hook reason — both are logged — so this one is handed back to the CLI's
        /// own prompt instead of being answered here.
        let isSecret: Bool

        /// Identity is the agent's key, not the question text. Two questions in one
        /// batch can read identically — "Which one?" twice — and keying a `ForEach`
        /// or a stepper on the text collapses them into one row.
        var id: String { key }

        /// No options at all. The only answer that can be given is typed.
        var isFreeTextOnly: Bool { options.isEmpty }

        init(
            question: String,
            header: String,
            options: [Option],
            multiSelect: Bool,
            key: String? = nil,
            allowsOther: Bool = false,
            isSecret: Bool = false
        ) {
            self.question = question
            self.header = header
            self.options = options
            self.multiSelect = multiSelect
            self.key = key ?? question
            self.allowsOther = allowsOther || options.isEmpty
            self.isSecret = isSecret
        }
    }

    let items: [Item]

    static func parse(_ input: JSONValue?) -> AgentQuestion? {
        guard let values = input?["questions"]?.arrayValue else { return nil }
        let items = values.compactMap { value -> Item? in
            guard let question = value.string("question") else { return nil }
            let options = (value["options"]?.arrayValue ?? []).compactMap { option -> Item.Option? in
                guard let label = option.string("label") else { return nil }
                return .init(label: label, description: option.string("description"))
            }
            // An optionless question used to be dropped here, which left Codex
            // blocked on a card that never appeared. It is a free-text question.
            return .init(
                question: question,
                header: value.string("header") ?? "Question",
                options: options,
                multiSelect: flag(value, "multiSelect", "multi_select"),
                key: value.string("id"),
                allowsOther: flag(value, "isOther", "is_other"),
                isSecret: flag(value, "isSecret", "is_secret")
            )
        }
        return items.isEmpty ? nil : AgentQuestion(items: items)
    }

    /// Codex's own schema is camelCase, but its transcripts have carried both.
    private static func flag(_ value: JSONValue, _ names: String...) -> Bool {
        names.contains { value[$0] == .bool(true) }
    }
}
