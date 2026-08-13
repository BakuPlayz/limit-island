import Foundation
import Observation

/// Every agent session the hooks have told us about, and every decision they are
/// waiting on.
///
/// `@Observable` rather than `ObservableObject` because the panel re-renders on a
/// timer for elapsed times: with a single `objectWillChange` publisher, one tick
/// would invalidate Settings too.
@MainActor
@Observable
final class SessionStore {
    struct CodexQuestionState: Equatable {
        let question: AgentQuestion
        let receivedAt: Date
    }

    enum ActiveInteraction {
        case pending(PendingRequest)
        case codex(session: AgentSession, state: CodexQuestionState)

        var id: String {
            switch self {
            case let .pending(request): "pending-\(request.id.uuidString)"
            case let .codex(session, _): "codex-\(session.id)"
            }
        }
    }

    /// Ordered for the panel: anything waiting on the person first, then by most
    /// recent activity.
    private(set) var sessions: [AgentSession] = []
    private(set) var pending: [PendingRequest] = []
    private(set) var codexQuestions: [String: CodexQuestionState] = [:]
    /// Bumped once a second so `elapsed` strings stay honest.
    private(set) var tick: Int = 0

    /// Which tools are decided from the notch. Everything else is reported but
    /// never intercepted — see `PermissionRules` for why this is a matcher and not
    /// simply "all of them".
    var approvalMatcher: String {
        didSet { UserDefaults.standard.set(approvalMatcher, forKey: DefaultsKey.matcher) }
    }

    /// How long a card waits before handing the decision back to the terminal. Kept
    /// below the hook timeout configured in settings.json so the CLI is never cut
    /// off mid-decision.
    nonisolated static let decisionTimeout: Duration = .seconds(480)
    private enum DefaultsKey {
        static let matcher = "limit-island.approval-matcher"
    }

    nonisolated static let defaultMatcher = "Bash|Edit|MultiEdit|Write|NotebookEdit|WebFetch|ExitPlanMode"

    private var housekeeping: Task<Void, Never>?
    private var livenessTicks = 0

    init() {
        approvalMatcher = UserDefaults.standard.string(forKey: DefaultsKey.matcher) ?? Self.defaultMatcher
    }

    func start() {
        housekeeping?.cancel()
        housekeeping = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                self.tick &+= 1
                self.livenessTicks += 1
                if self.livenessTicks >= 5 {
                    self.livenessTicks = 0
                    self.removeClosedSessions()
                }
            }
        }
    }

    func stop() {
        housekeeping?.cancel()
        housekeeping = nil
        // Anything still blocked has to be released, or quitting the app would
        // leave the user's agents hanging on a socket that no longer exists.
        for request in pending { request.defer_() }
        pending.removeAll()
    }

    // MARK: - Events

    /// Handles one hook event and produces the CLI's answer.
    func handle(_ event: HookEvent) async -> (HookReply, String?) {
        // Codex's `notify` arrives before the session-id guard: its payload has no
        // session id of the kind Claude Code sends, and the row it belongs to was
        // created from the transcript, not from here.
        if event.event == "notify" {
            attachCodexTerminal(
                TerminalRef(event: event),
                sessionID: event.sessionID,
                workingDirectory: event.workingDirectory
            )
            return (.noOpinion, nil)
        }

        // Claude injects completed background work into its transcript as a
        // synthetic user message. It is not a prompt typed by the person and must
        // neither create a row nor replace the row's useful title.
        if event.event == "UserPromptSubmit", event.prompt?.isTaskNotification == true {
            return (.noOpinion, nil)
        }

        guard let sessionID = event.sessionID else { return (.noOpinion, nil) }
        touch(event, id: sessionID)

        // Mode-bearing hooks are also how Claude tells us someone changed modes
        // while an older permission card was already waiting. Resolve that card
        // immediately instead of leaving a stale interruption on screen.
        if event.permissionMode.isAutomatic {
            allowPendingForAutoMode(sessionID: sessionID)
        }

        switch event.event {
        case "SessionStart":
            update(sessionID) { $0.activity = .starting }
        case "UserPromptSubmit":
            update(sessionID) {
                if let prompt = event.prompt { $0.lastPrompt = prompt }
                $0.activity = .thinking
            }
        case "PreToolUse":
            return await handlePreToolUse(event, sessionID: sessionID)
        case "PermissionRequest":
            return await handlePermission(event, sessionID: sessionID)
        case "PostToolUse":
            // The call went through, so any card still up for it is moot — most
            // likely the person answered in the terminal instead.
            resolvePending(sessionID: sessionID, tool: event.toolName)
            update(sessionID) { $0.activity = .thinking }
        case "Notification":
            switch event.notificationType {
            case .permissionPrompt, .elicitationDialog:
                // Do not replace a richer card that Limit Island is already
                // presenting for this session.
                guard !pending.contains(where: { $0.sessionID == sessionID }) else { break }
                update(sessionID) {
                    $0.activity = .waitingInTerminal(event.message ?? "Waiting in the terminal")
                }
            case .idlePrompt:
                update(sessionID) { $0.activity = .done }
            case .passive, .unknown:
                break
            }
        case "Stop", "SubagentStop":
            update(sessionID) { $0.activity = .done }
        case "SessionEnd":
            resolvePending(sessionID: sessionID, tool: nil)
            sessions.removeAll { $0.id == sessionID }
            codexQuestions[sessionID] = nil
        default:
            break
        }
        return (.noOpinion, nil)
    }

    private func handlePreToolUse(_ event: HookEvent, sessionID: String) async -> (HookReply, String?) {
        guard let tool = event.toolName else { return (.noOpinion, nil) }
        update(sessionID) { $0.activity = .running(ToolSummary.activity(tool: tool, input: event.toolInput)) }

        if tool == "ExitPlanMode" { return (.noOpinion, nil) }

        // AskUserQuestion does not require Claude's normal permission prompt, but
        // its PreToolUse hook can still block and return the completed answers.
        if tool == "AskUserQuestion", AgentQuestion.parse(event.toolInput) != nil {
            return await decide(event, sessionID: sessionID, tool: tool)
        }

        guard shouldIntercept(tool: tool) else { return (.noOpinion, nil) }

        // Auto-accept and bypass mean the person has already answered. Showing a
        // card there would put back exactly the interruption they turned off — so
        // the session is reported as usual and the call goes straight through.
        let mode = event.permissionMode
        guard mode.asksAbout(tool) else {
            Log.hooks.debug("\(tool, privacy: .public) not intercepted: session is in \(String(describing: mode), privacy: .public)")
            return (.noOpinion, nil)
        }

        // The user's own rules come first. A call they have already allowlisted
        // must not start asking again just because Limit Island is running.
        // Loaded off the main actor: it is three file reads, and the UI should not
        // stall on them just because an agent reached for a tool.
        let directory = event.workingDirectory
        let rules = await Task.detached { PermissionRules.load(projectDirectory: directory) }.value
        let outcome = rules.outcome(tool: tool, input: event.toolInput)
        Log.hooks.debug("""
            \(tool, privacy: .public) in \(directory ?? "no cwd", privacy: .public): \
            rules say \(String(describing: outcome), privacy: .public)
            """)
        switch outcome {
        case .allowed, .denied:
            return (.noOpinion, nil)
        case .undecided:
            break
        }

        return await decide(event, sessionID: sessionID, tool: tool)
    }

    private func shouldIntercept(tool: String) -> Bool {
        // Only Claude Code can be answered through its hook; the others report.
        guard !approvalMatcher.isEmpty else { return false }
        return approvalMatcher.split(separator: "|").contains { $0.trimmingCharacters(in: .whitespaces) == tool }
    }

    private func decide(_ event: HookEvent, sessionID: String, tool: String) async -> (HookReply, String?) {
        update(sessionID) { $0.activity = .awaitingDecision }

        let answer = await withCheckedContinuation { (continuation: CheckedContinuation<(HookReply, String?), Never>) in
            // `resumed` guards the one invariant that matters: a continuation
            // resumed twice traps, and a continuation never resumed hangs a coding
            // agent until its hook times out.
            nonisolated(unsafe) var resumed = false
            let request = PendingRequest(
                sessionID: sessionID,
                provider: event.provider,
                tool: tool,
                input: event.toolInput
            ) { reply, reason in
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: (reply, reason))
            }
            pending.append(request)

            Task { [weak self] in
                try? await Task.sleep(for: Self.decisionTimeout)
                guard let self, self.pending.contains(where: { $0.id == request.id }) else { return }
                // Timing out is not a denial. Handing the decision back means the
                // person still gets Claude Code's own prompt in the terminal.
                Log.hooks.info("decision for \(tool, privacy: .public) timed out; deferring to the CLI")
                request.defer_()
                self.pending.removeAll { $0.id == request.id }
            }
        }

        pending.removeAll { $0.sessionID == sessionID && $0.tool == tool }
        if tool != "AskUserQuestion" { update(sessionID) { $0.activity = .thinking } }
        return answer
    }

    // MARK: - Codex

    /// Applies one line of a Codex rollout file.
    ///
    /// Codex sessions reach the panel this way rather than through hooks: it has no
    /// hook that can be asked a question, and its `notify` fires only when a turn
    /// ends. The transcript is what makes a Codex row live rather than a row that
    /// updates twice a minute.
    func apply(_ update: CodexSessionWatcher.Update) {
        let id = update.sessionID

        switch update.record {
        case let .started(_, directory, source):
            guard source != .subagent else { return }
            insertIfNeeded(id, provider: .openAI, directory: directory ?? update.workingDirectory)
        case let .prompt(text):
            clearCodexQuestion(id, activity: .thinking)
            insertIfNeeded(id, provider: .openAI, directory: update.workingDirectory)
            self.update(id) {
                $0.lastPrompt = text
                $0.activity = .thinking
            }
        case .turnStarted:
            clearCodexQuestion(id, activity: .thinking)
            insertIfNeeded(id, provider: .openAI, directory: update.workingDirectory)
            self.update(id) { $0.activity = .thinking }
        case .turnCompleted:
            codexQuestions[id] = nil
            self.update(id) { $0.activity = .done }
        case let .activity(what):
            codexQuestions[id] = nil
            insertIfNeeded(id, provider: .openAI, directory: update.workingDirectory)
            self.update(id) { $0.activity = .running(what) }
        case let .question(question):
            insertIfNeeded(id, provider: .openAI, directory: update.workingDirectory)
            codexQuestions[id] = CodexQuestionState(question: question, receivedAt: .now)
            self.update(id) { $0.activity = .waitingInTerminal(question.items.first?.question ?? "Codex is waiting") }
        case .functionAnswered:
            clearCodexQuestion(id, activity: .thinking)
        case let .approvalPolicy(mode):
            codexModes[id] = mode
            if mode.isAutomatic { allowPendingForAutoMode(sessionID: id) }
        }
    }

    /// Codex's own approval policy per session. Recorded for the same reason Claude
    /// Code's `permission_mode` is: a session the person has set to ask for nothing
    /// should not be interrupted on its behalf.
    private var codexModes: [String: PermissionMode] = [:]

    private func handlePermission(_ event: HookEvent, sessionID: String) async -> (HookReply, String?) {
        guard let tool = event.toolName else { return (.noOpinion, nil) }
        if event.provider == .claude {
            guard tool == "ExitPlanMode" else { return (.noOpinion, nil) }
            return await decide(event, sessionID: sessionID, tool: tool)
        }
        // Newer Codex/Sol hook payloads carry the policy directly. Honour it even
        // when the transcript setting has not reached the watcher yet.
        guard event.permissionMode != .bypass else { return (.noOpinion, nil) }
        guard codexModes[sessionID] != .bypass else { return (.noOpinion, nil) }
        return await decide(event, sessionID: sessionID, tool: tool)
    }

    func dismissCodexQuestion(sessionID: String) {
        clearCodexQuestion(sessionID, activity: .thinking)
    }

    private func clearCodexQuestion(_ sessionID: String, activity: SessionActivity) {
        guard codexQuestions.removeValue(forKey: sessionID) != nil else { return }
        update(sessionID) { $0.activity = activity }
    }

    /// One interaction is actionable at a time. Comparing the time each request
    /// actually arrived keeps multiple agents in a predictable first-in-first-out
    /// queue instead of letting a recently active session jump the line.
    var activeInteraction: ActiveInteraction? {
        let firstPending = pending.min { $0.receivedAt < $1.receivedAt }
        let firstCodex = codexQuestions.min { $0.value.receivedAt < $1.value.receivedAt }

        if let firstPending,
           firstCodex == nil || firstPending.receivedAt <= firstCodex!.value.receivedAt {
            return .pending(firstPending)
        }
        guard let firstCodex,
              let session = session(id: firstCodex.key) else { return nil }
        return .codex(session: session, state: firstCodex.value)
    }

    var waitingInteractionCount: Int { pending.count + codexQuestions.count }

    /// The terminal a Codex session is running in, learned from its `notify` hook —
    /// rollout files do not record the environment. Prefer the notify payload's
    /// session id; older payloads fall back to a directory only when it identifies
    /// exactly one live Codex session.
    func attachCodexTerminal(_ terminal: TerminalRef, sessionID: String?, workingDirectory: String?) {
        if let sessionID, let index = sessions.firstIndex(where: { $0.id == sessionID && $0.provider == .openAI }) {
            sessions[index].terminal = terminal
            coalesceSessions(preferredID: sessionID)
            return
        }
        guard let workingDirectory else { return }
        let name = (workingDirectory as NSString).lastPathComponent
        let candidates = sessions.indices.filter {
            sessions[$0].provider == .openAI && sessions[$0].project == name && sessions[$0].terminal == nil
        }
        guard candidates.count == 1, let index = candidates.first else { return }
        sessions[index].terminal = terminal
        coalesceSessions(preferredID: sessions[index].id)
    }

    private func insertIfNeeded(_ id: String, provider: Provider, directory: String?) {
        if let index = sessions.firstIndex(where: { $0.id == id }) {
            sessions[index].lastEventAt = .now
            if sessions[index].lastPrompt?.isTaskNotification == true {
                sessions[index].lastPrompt = nil
            }
            if let directory, sessions[index].project == nil {
                sessions[index].project = (directory as NSString).lastPathComponent
            }
            return
        }
        sessions.append(AgentSession(
            id: id,
            provider: provider,
            project: directory.map { ($0 as NSString).lastPathComponent },
            lastPrompt: nil,
            activity: .starting,
            terminal: nil,
            startedAt: .now,
            lastEventAt: .now
        ))
        discoverCodexTerminal(for: id, directory: directory)
        reorder()
    }

    /// Rollout activity arrives before Codex's end-of-turn notify callback. Resolve
    /// the live process immediately so questions and in-progress rows can already
    /// jump to their terminal instead of silently doing nothing.
    private func discoverCodexTerminal(for id: String, directory: String?) {
        guard let directory else { return }
        Task.detached {
            let terminal = TerminalDiscovery.codex(in: directory)
            await MainActor.run { [weak self] in
                guard let self, let terminal,
                      let index = self.sessions.firstIndex(where: { $0.id == id }),
                      self.sessions[index].terminal == nil else { return }
                self.sessions[index].terminal = terminal
                self.coalesceSessions(preferredID: id)
            }
        }
    }

    func selectDestination(_ destination: TerminalDestination, for sessionID: String) {
        update(sessionID) { $0.selectedDestination = destination }
    }

    func removeSession(_ sessionID: String) {
        resolvePending(sessionID: sessionID, tool: nil)
        sessions.removeAll { $0.id == sessionID }
        codexQuestions[sessionID] = nil
    }

    func session(id: String) -> AgentSession? {
        sessions.first { $0.id == id }
    }

    // MARK: - Decisions from the UI

    func allow(_ request: PendingRequest) {
        request.allow()
        // A decision the request refused as too fast leaves the card up; removing it
        // would take the question off screen while the CLI still waited for it.
        guard request.isResolved else { return }
        Log.hooks.info("allowed \(request.tool, privacy: .public) for \(request.sessionID, privacy: .public)")
        pending.removeAll { $0.id == request.id }
    }

    func deny(_ request: PendingRequest) {
        request.deny()
        guard request.isResolved else { return }
        Log.hooks.info("denied \(request.tool, privacy: .public) for \(request.sessionID, privacy: .public)")
        pending.removeAll { $0.id == request.id }
    }

    func answer(_ request: PendingRequest, answers: [String: String]) {
        request.answer(answers)
        guard request.isResolved else { return }
        pending.removeAll { $0.id == request.id }
        update(request.sessionID) { $0.activity = .thinking }
    }

    func approvePlan(_ request: PendingRequest, automatic: Bool) {
        request.approvePlan(automatic: automatic)
        removeResolved(request)
    }

    func requestPlanChanges(_ request: PendingRequest, feedback: String) {
        request.requestPlanChanges(feedback)
        removeResolved(request)
    }

    private func removeResolved(_ request: PendingRequest) {
        guard request.isResolved else { return }
        pending.removeAll { $0.id == request.id }
        update(request.sessionID) { $0.activity = .thinking }
    }

    /// Dismisses a card without answering: the CLI's own prompt takes over.
    func dismiss(_ request: PendingRequest) {
        request.defer_()
        pending.removeAll { $0.id == request.id }
    }

    private func resolvePending(sessionID: String, tool: String?) {
        for request in pending where request.sessionID == sessionID && (tool == nil || request.tool == tool) {
            request.defer_()
        }
        pending.removeAll { $0.sessionID == sessionID && (tool == nil || $0.tool == tool) }
    }

    private func allowPendingForAutoMode(sessionID: String) {
        let requests = pending.filter {
            $0.sessionID == sessionID && $0.tool != "AskUserQuestion"
        }
        guard !requests.isEmpty else { return }
        for request in requests { request.allowForAutoMode() }
        let ids = Set(requests.map(\.id))
        pending.removeAll { ids.contains($0.id) }
        update(sessionID) { $0.activity = .thinking }
    }

    // MARK: - Session bookkeeping

    private func touch(_ event: HookEvent, id: String) {
        let terminal = TerminalDiscovery.enriched(TerminalRef(event: event))
        if let index = sessions.firstIndex(where: { $0.id == id }) {
            sessions[index].lastEventAt = .now
            // The terminal is re-sent on every event, which is what keeps a session
            // resumed in a different window pointing at the right one.
            if !terminal.pids.isEmpty { sessions[index].terminal = terminal }
            if let directory = event.workingDirectory {
                sessions[index].project = (directory as NSString).lastPathComponent
            }
            reorder()
            if event.provider == .openAI { coalesceSessions(preferredID: id) }
            return
        }
        sessions.insert(
            AgentSession(
                id: id,
                provider: event.provider,
                project: event.workingDirectory.map { ($0 as NSString).lastPathComponent },
                lastPrompt: event.prompt,
                activity: .starting,
                terminal: terminal,
                startedAt: .now,
                lastEventAt: .now
            ),
            at: 0
        )
        if event.provider == .openAI { coalesceSessions(preferredID: id) }
    }

    /// Coalesces only exact runtime identities. Matching titles or projects are
    /// intentionally irrelevant: two agents doing the same work in separate panes
    /// are two sessions and both remain visible.
    private func coalesceSessions(preferredID: String) {
        guard let preferredIndex = sessions.firstIndex(where: { $0.id == preferredID }),
              let identity = sessions[preferredIndex].terminal?.stableIdentity else { return }
        let duplicates = sessions.indices.filter {
            $0 != preferredIndex && sessions[$0].terminal?.stableIdentity == identity
        }
        guard !duplicates.isEmpty else { return }

        var retained = sessions[preferredIndex]
        for index in duplicates {
            let stale = sessions[index]
            if retained.lastPrompt == nil { retained.lastPrompt = stale.lastPrompt }
            if retained.project == nil { retained.project = stale.project }
            if retained.terminal == nil { retained.terminal = stale.terminal }
            retained.startedAt = min(retained.startedAt, stale.startedAt)
            codexQuestions[stale.id] = nil
            resolvePending(sessionID: stale.id, tool: nil)
        }
        let duplicateIDs = Set(duplicates.map { sessions[$0].id })
        sessions.removeAll { duplicateIDs.contains($0.id) }
        if let index = sessions.firstIndex(where: { $0.id == preferredID }) { sessions[index] = retained }
        reorder()
    }

    private func update(_ id: String, _ change: (inout AgentSession) -> Void) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        change(&sessions[index])
        reorder()
    }

    private func removeClosedSessions() {
        let closed = sessions.filter {
            guard let pid = $0.terminal?.agentPID else { return false }
            return !TerminalDiscovery.isProcessAlive(pid)
        }
        guard !closed.isEmpty else { return }
        for session in closed { resolvePending(sessionID: session.id, tool: nil) }
        let ids = Set(closed.map(\.id))
        sessions.removeAll { ids.contains($0.id) }
    }

    /// Anything waiting on the person comes first — that is the row they need to act
    /// on — and the rest stay in most-recently-active order.
    private func reorder() {
        sessions.sort { left, right in
            if left.activity.isWaiting != right.activity.isWaiting {
                return left.activity.isWaiting
            }
            return left.lastEventAt > right.lastEventAt
        }
    }

    /// True while any session is holding for the person, whether that is a card of
    /// ours or the CLI's own prompt. The window controller opens the panel for it.
    var isWaitingOnUser: Bool {
        !pending.isEmpty || sessions.contains { $0.activity.isWaiting }
    }
}

private extension String {
    var isTaskNotification: Bool {
        trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<task-notification>")
    }
}
