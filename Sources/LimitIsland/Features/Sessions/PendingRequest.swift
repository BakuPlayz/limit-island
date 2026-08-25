import Foundation

/// A question an agent is holding for, and the continuation that answers it.
///
/// The CLI's hook process is blocked on a socket read while this exists, so a
/// request that is never resolved is a coding agent that never continues. Two rules
/// follow, and both are enforced by `SessionStore`:
///
/// * every request resolves exactly once, and
/// * every request has a deadline, whose expiry resolves it as *no opinion* rather
///   than as a denial — a timeout must hand control back to the terminal, not
///   decide on the user's behalf.
@MainActor
final class PendingRequest: Identifiable {
    let id = UUID()
    let sessionID: String
    let provider: Provider
    let tool: String
    let input: JSONValue?
    let receivedAt = Date.now

    private var resume: ((HookReply, String?) -> Void)?

    /// False while the CLI is still waiting. The store uses this to decide whether
    /// a card may leave the panel: a rejected decision must not take the card away
    /// and strand the hook with nothing to answer it.
    var isResolved: Bool { resume == nil }

    init(
        sessionID: String,
        provider: Provider,
        tool: String,
        input: JSONValue?,
        resume: @escaping (HookReply, String?) -> Void
    ) {
        self.sessionID = sessionID
        self.provider = provider
        self.tool = tool
        self.input = input
        self.resume = resume
    }

    var kind: Kind {
        switch tool {
        case "AskUserQuestion", "request_user_input": .question(AgentQuestion.parse(input))
        case "ExitPlanMode": .plan(input?.string("plan") ?? "")
        case "Edit", "MultiEdit", "Write", "NotebookEdit": .edit
        default: .general
        }
    }

    enum Kind: Equatable {
        case edit
        case plan(String)
        case general
        case question(AgentQuestion?)
    }

    var title: String { ToolSummary.activity(tool: tool, input: input) }
    var target: String? { ToolSummary.target(tool: tool, input: input) }

    /// Nobody reads a diff in a third of a second.
    ///
    /// This is a backstop, and it earned its place: a card once resolved itself with
    /// the pointer parked in the opposite corner of the screen and nothing typed —
    /// the button's own action fired. The two causes found are fixed elsewhere (the
    /// panel can no longer take key status, and the buttons are no longer `Button`s),
    /// but neither was proven to be *the* trigger. A decision that arrives faster
    /// than a person can read is not a person, whatever produced it.
    static let minimumDeliberationTime: TimeInterval = 0.4

    private var isTooSoon: Bool {
        Date.now.timeIntervalSince(receivedAt) < Self.minimumDeliberationTime
    }

    func allow() {
        guard !isTooSoon else { return reject("allow") }
        finish(.init(decision: .allow), "Approved from Limit Island")
    }

    /// A session switching to auto mode is itself an explicit permission choice,
    /// so it must not be delayed by the human-click deliberation guard.
    func allowForAutoMode() {
        finish(.init(decision: .allow), "Approved because the session entered auto mode")
    }

    func deny() {
        guard !isTooSoon else { return reject("deny") }
        finish(.init(decision: .deny), "Denied from Limit Island")
    }

    func answer(_ answers: [String: String]) {
        guard !isTooSoon else { return reject("answer") }

        // Codex cannot be handed an answer the way Claude can, so its question is
        // refused and the answers ride back as the refusal's reason. Blocking the
        // call is also what stops Codex drawing its own picker in the terminal —
        // the two would otherwise both be waiting for the same person.
        if provider == .openAI {
            finish(.init(decision: .deny), CodexAnswerText.render(answers, for: AgentQuestion.parse(input)))
            return
        }

        guard case let .object(original) = input else { return }
        var updated = original
        updated["answers"] = .object(answers.mapValues(JSONValue.string))
        finish(.init(decision: .allow, updatedInput: .object(updated)), "Answered from Limit Island")
    }

    /// The mode rides along only when the person asked for one. "Ask before each
    /// edit" is a choice about being asked, not a request to reset a session that
    /// was already running in some other mode of its own.
    func approvePlan(automatic: Bool) {
        guard !isTooSoon else { return reject("approve plan") }
        finish(
            .init(
                decision: .allow,
                updatedInput: input,
                updatedPermissionMode: automatic ? PermissionMode.autoApprove : nil
            ),
            "Plan approved from Limit Island"
        )
    }

    /// "No, keep planning" — with or without something to add. The feedback is what
    /// the CLI reports back to the agent as the reason it may not build yet, so an
    /// empty one still has to say something the agent can act on.
    func requestPlanChanges(_ feedback: String) {
        guard !isTooSoon else { return reject("request plan changes") }
        let trimmed = feedback.trimmingCharacters(in: .whitespacesAndNewlines)
        finish(.init(decision: .deny), trimmed.isEmpty ? "Keep planning. The plan was not approved." : trimmed)
    }

    /// Hands the decision back to the CLI's own prompt. Used on timeout, on quit,
    /// and when the person answers in the terminal instead. Never rate-limited:
    /// deferring is always safe, and delaying it would hold up a CLI.
    func defer_() { finish(.noOpinion, nil) }

    private func reject(_ what: String) {
        // Loud on purpose. If this ever fires in normal use, something is answering
        // permission requests that is not the person sitting at the machine.
        Log.hooks.error("""
            ignored a \(what, privacy: .public) for \(self.tool, privacy: .public) \
            arriving \(Date.now.timeIntervalSince(self.receivedAt), format: .fixed(precision: 3))s \
            after the card appeared — too fast to be deliberate
            """)
    }

    private func finish(_ reply: HookReply, _ reason: String?) {
        guard let resume else { return }
        self.resume = nil
        resume(reply, reason)
    }
}
