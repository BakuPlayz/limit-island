import Foundation

/// Renders answers into the sentence Codex's model reads as the result of its own
/// question.
///
/// Codex has no way to be *handed* an answer. Claude's `AskUserQuestion` reads
/// answers pre-filled into `updatedInput`, but `request_user_input` does not, and
/// hooks offer exactly one channel that reaches the model: the reason a call was
/// refused. So the call is blocked and the answers travel as the reason, which Codex
/// surfaces to the model as `Tool call blocked by PreToolUse hook: <reason>`.
///
/// That framing is why the wording is fixed here rather than assembled at the call
/// site. The model is being told its tool failed; the text has to make it obvious
/// that the *question was answered anyway*, and that re-asking is not the recovery.
/// Both sentences were checked against a live Codex 0.147 session — with them, the
/// model restated all three answers and continued without asking again.
enum CodexAnswerText {
    static let preamble = """
        The user answered these questions in Limit Island; request_user_input was not \
        shown in the terminal. Do not ask them again.
        """

    /// - Parameters:
    ///   - answers: keyed by question *text*, which is how the card collects them.
    ///   - question: supplies each question's Codex `id`, the key its own answer
    ///     payload uses and the one the model already associates with the question.
    static func render(_ answers: [String: String], for question: AgentQuestion?) -> String {
        // Question order, not dictionary order: an unordered list of answers invites
        // the model to pair them with the wrong questions.
        let lines: [String]
        if let items = question?.items, !items.isEmpty {
            lines = items.compactMap { item in
                guard let answer = answers[item.question]?.trimmed, !answer.isEmpty else { return nil }
                return "\(item.key): \(answer)"
            }
        } else {
            lines = answers.sorted { $0.key < $1.key }.compactMap { key, value in
                guard let answer = value.trimmed, !answer.isEmpty else { return nil }
                return "\(key): \(answer)"
            }
        }

        guard !lines.isEmpty else { return preamble }
        return preamble + "\n\n" + lines.joined(separator: "\n")
    }
}

private extension String {
    var trimmed: String? { trimmingCharacters(in: .whitespacesAndNewlines) }
}
