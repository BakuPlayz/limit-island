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

    /// Questions this session already raised as a card from Codex's `PreToolUse`
    /// hook, so the transcript watcher does not raise them a second time.
    ///
    /// Kept per session and cleared when the turn ends. It is a small list by
    /// construction — a turn asks a question or two — and capped anyway, because a
    /// session that loops asking must not grow this without bound.
    private var codexHookQuestions: [String: [AgentQuestion]] = [:]
    private static let codexHookQuestionMemory = 8
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

    /// The plan each session was last shown a card for.
    ///
    /// `ExitPlanMode` is offered to us twice — once as `PreToolUse`, once as
    /// `PermissionRequest` — and the person must read a plan once, not twice. Keyed on
    /// the plan's own text rather than the session, because an agent told to keep
    /// planning comes straight back with a *different* plan, and that one is a new
    /// question.
    private var plansShown: [String: String] = [:]

    /// Sessions where the person approved a plan with "auto approve".
    ///
    /// Answering the hook with a mode switch only works if the CLI honours it, and
    /// that cannot be relied on across versions. Remembering the choice here makes
    /// the promise ours to keep: edits from this session are allowed without a card
    /// until it ends or plans again, which is what accept-edits means.
    private(set) var autoApprovedPlans: Set<String> = []

    /// Where a session has got to in the handover from "auto approve" to the CLI's
    /// own permission mode.
    ///
    /// The switch cannot travel with the approval itself. `ExitPlanMode` is answered
    /// on `PreToolUse`, whose reply has no field for a permission mode at all, and
    /// even if it did, the tool ends by setting the session's mode to whatever
    /// preceded plan mode — so anything sent before it runs is overwritten. The next
    /// `PermissionRequest` is the first moment a switch survives.
    ///
    /// Two states rather than a flag because sending a switch is not the same as
    /// having made one: only the mode reported by a later event settles that, and a
    /// session that never reports the mode back is one whose promise is still ours.
    private enum ModeHandover: Equatable {
        case owed(String)
        case sent(String)
    }
    private var modeHandovers: [String: ModeHandover] = [:]

    /// How many edits may be handed back to the terminal while waiting for the one
    /// event that can carry a mode switch.
    ///
    /// The wait has to be bounded. A `PermissionRequest` only fires when the CLI is
    /// about to ask, so a session whose edits are already covered by the person's own
    /// allow-rules never produces one — and an unbounded wait would defer every edit
    /// forever, which is neither the switch nor the promise the button made.
    private static let maxEditsDeferredForSwitch = 1
    private var editsDeferredForSwitch: [String: Int] = [:]

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
        // The trace that answers "are the hooks even reaching the app?". Nothing of
        // what the person is doing: the CLI, the event, and whether it identified a
        // session — which is the whole of what deciding to show a row depends on.
        Log.hooks.debug("""
            \(event.cli, privacy: .public) \(event.event, privacy: .public) \
            \(event.sessionID == nil ? "without a session id" : "for a session", privacy: .public)
            """)
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

        guard let sessionID = event.sessionID else {
            if event.provider == .gemini {
                // The one failure that would leave the island silent while the hooks
                // are demonstrably firing. Name the keys rather than the payload:
                // enough to see a renamed field, nothing of what the person is doing.
                Log.hooks.debug("""
                    gemini \(event.event, privacy: .public) has no conversation id; \
                    keys: \(event.payload.objectValue?.keys.sorted().joined(separator: ",") ?? "none", privacy: .public)
                    """)
            }
            return (.noOpinion, nil)
        }
        // Antigravity's hooks are global — the CLI, the IDE and the desktop app read
        // the same file, and it runs internal conversations of its own. A workspace
        // is what makes an event a session someone is sitting in front of, so an
        // event without one may update a row we already know but never open one.
        if event.provider == .gemini, event.workingDirectory == nil, session(id: sessionID) == nil {
            return (.noOpinion, nil)
        }
        touch(event, id: sessionID)

        // Mode-bearing hooks are also how Claude tells us someone changed modes
        // while an older permission card was already waiting. Resolve that card
        // immediately instead of leaving a stale interruption on screen.
        if event.permissionMode.isAutomatic {
            allowPendingForAutoMode(sessionID: sessionID)
        }
        if let reported = event.reportedPermissionMode {
            reconcileModeHandover(reported, sessionID: sessionID)
        }

        switch event.event {
        case "SessionStart":
            update(sessionID) { $0.activity = .starting }
            readClaudeModel(event, sessionID: sessionID)
        // Antigravity has no session-start event: the first thing a turn does is
        // call the model, and that is where a Gemini row begins. `PostInvocation`
        // is a continuation hint rather than a state change, so it only touches.
        case "PreInvocation":
            update(sessionID) { $0.activity = .thinking }
            readGeminiPrompt(sessionID: sessionID)
        case "PostInvocation":
            break
        case "UserPromptSubmit":
            // A new instruction ends the plan that was answered under the old one.
            plansShown[sessionID] = nil
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
            readClaudeModel(event, sessionID: sessionID)
        case "SessionEnd":
            resolvePending(sessionID: sessionID, tool: nil)
            sessions.removeAll { $0.id == sessionID }
            codexQuestions[sessionID] = nil
            codexHookQuestions[sessionID] = nil
            plansShown[sessionID] = nil
            autoApprovedPlans.remove(sessionID)
            modeHandovers[sessionID] = nil
            editsDeferredForSwitch[sessionID] = nil
        default:
            break
        }
        return (.noOpinion, nil)
    }

    /// Reads the model out of a Claude session's transcript.
    ///
    /// Claude Code's hook payloads name the transcript but not the model, and the
    /// transcript names the model on every assistant turn. Called only at the two
    /// ends of a turn — a tool loop can fire ten `PreToolUse` events a second, and
    /// none of them would say anything a file read at the end does not.
    private func readClaudeModel(_ event: HookEvent, sessionID: String) {
        guard event.provider == .claude, let path = event.transcriptPath else { return }
        Task.detached(priority: .utility) {
            guard let model = ClaudeTranscriptAdopter.model(atPath: path) else { return }
            await MainActor.run { [weak self] in
                self?.update(sessionID) { $0.model = model }
            }
        }
    }

    /// Titles a Gemini row with what the person actually asked for.
    ///
    /// Read at the start of a turn, which is the one moment a new prompt exists and
    /// the only Antigravity event that follows one — see `GeminiHistoryReader` for
    /// why the prompt has to be fetched rather than delivered.
    private func readGeminiPrompt(sessionID: String) {
        Task.detached(priority: .utility) {
            guard let prompt = GeminiHistoryReader.lastPrompt(conversationID: sessionID) else { return }
            await MainActor.run { [weak self] in
                self?.update(sessionID) { $0.lastPrompt = prompt }
            }
        }
    }

    /// Checks what the CLI actually did with a mode switch we sent.
    ///
    /// There is nothing to ask for a second time. Accept-edits is not gated the way
    /// Claude's own `auto` is, so a session reading back `default` after we set it has
    /// refused something it had no documented reason to refuse — worth a log line, not
    /// a retry ladder. The promise then stays ours to keep through `autoApprovedPlans`,
    /// and the worst case is the behaviour that shipped before any of this existed.
    ///
    /// Takes a mode the event actually reported. An event that carried no mode at all
    /// must not be read as a refusal — see `HookEvent.reportedPermissionMode`.
    private func reconcileModeHandover(_ mode: PermissionMode, sessionID: String) {
        guard case let .sent(requested) = modeHandovers[sessionID] else { return }
        modeHandovers[sessionID] = nil
        switch mode {
        case .auto, .acceptEdits, .bypass:
            break
        case .standard, .plan:
            Log.hooks.info("""
                \(sessionID, privacy: .public) did not take \(requested, privacy: .public); \
                keeping the plan's promise in the app instead
                """)
        }
    }

    private func handlePreToolUse(_ event: HookEvent, sessionID: String) async -> (HookReply, String?) {
        guard let tool = event.toolName else { return (.noOpinion, nil) }
        update(sessionID) { $0.activity = .running(ToolSummary.activity(tool: tool, input: event.toolInput)) }

        // A plan is not a tool permission: the user's allow-rules and the approval
        // matcher have no say in whether they get to read it, so this branch comes
        // before both. `PreToolUse` is also the earlier of the two events the CLI
        // offers it on, and the only one every build is known to send.
        if tool == "ExitPlanMode" {
            let plan = event.toolInput?.string("plan") ?? ""
            guard event.permissionMode.asksAbout(tool), plansShown[sessionID] != plan else {
                return (.noOpinion, nil)
            }
            plansShown[sessionID] = plan
            // Planning again replaces the answer given to the previous plan.
            autoApprovedPlans.remove(sessionID)
            modeHandovers[sessionID] = nil
            editsDeferredForSwitch[sessionID] = nil
            return await decide(event, sessionID: sessionID, tool: tool)
        }

        // AskUserQuestion does not require Claude's normal permission prompt, but
        // its PreToolUse hook can still block and return the completed answers.
        if tool == "AskUserQuestion", AgentQuestion.parse(event.toolInput) != nil {
            return await decide(event, sessionID: sessionID, tool: tool)
        }

        // Codex's question tool. Deliberately not behind `asksAbout`: a permission
        // mode says how much the person wants to be *asked to approve things*, and
        // a question is not an approval — nobody turns on auto-accept meaning "answer
        // my questions for me". Deferring here would just move the same question to
        // the terminal.
        if tool == "request_user_input", let question = AgentQuestion.parse(event.toolInput) {
            // A credential must not be typed into a floating panel or written into a
            // hook reason, and the reason is logged. Codex's own prompt takes it.
            guard !question.items.contains(where: \.isSecret) else {
                update(sessionID) { $0.activity = .waitingInTerminal("Waiting for a secret in the terminal") }
                return (.noOpinion, nil)
            }
            var seen = codexHookQuestions[sessionID, default: []]
            seen.append(question)
            codexHookQuestions[sessionID] = seen.suffix(Self.codexHookQuestionMemory)
            return await decide(event, sessionID: sessionID, tool: tool)
        }

        guard shouldIntercept(tool: tool, provider: event.provider) else { return (.noOpinion, nil) }

        // Auto-accept and bypass mean the person has already answered. Showing a
        // card there would put back exactly the interruption they turned off — so
        // the session is reported as usual and the call goes straight through.
        let mode = event.permissionMode
        guard mode.asksAbout(tool) else {
            Log.hooks.debug("\(tool, privacy: .public) not intercepted: session is in \(String(describing: mode), privacy: .public)")
            return (.noOpinion, nil)
        }

        // The person approved this session's plan with "auto approve", so the edits
        // that plan described are already answered. Asking again per file would put
        // back the interruption they just turned off. Deliberately only the edit
        // tools — that is what accept-edits means, and a command is not an edit.
        if autoApprovedPlans.contains(sessionID), PermissionMode.editTools.contains(tool) {
            // Standing down on purpose while a mode switch is owed. Answering `allow`
            // here settles this one edit and ends the turn — the CLI never runs its
            // permission flow, so the `PermissionRequest` that can carry the switch
            // never fires, and every later edit costs another card. Deferring once
            // buys the switch that makes all of them unnecessary.
            //
            // Only for as long as that trade can pay off, though: an edit the person's
            // own rules already allow produces no permission flow to wait for, and a
            // session that never asks would otherwise defer every edit for the rest of
            // its life. Past the bound, the plan's promise is answered here.
            if case .owed = modeHandovers[sessionID],
               editsDeferredForSwitch[sessionID, default: 0] < Self.maxEditsDeferredForSwitch {
                editsDeferredForSwitch[sessionID, default: 0] += 1
                return (.noOpinion, nil)
            }
            return (.init(decision: .allow), "Auto-approved by the plan you accepted")
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

    private func shouldIntercept(tool: String, provider: Provider = .claude) -> Bool {
        guard !approvalMatcher.isEmpty else { return false }
        let asked = Self.matcherName(for: tool, provider: provider)
        return approvalMatcher.split(separator: "|").contains { $0.trimmingCharacters(in: .whitespaces) == asked }
    }

    /// The name the approval list is written in.
    ///
    /// The list is one setting, typed once, in Claude Code's vocabulary. Antigravity
    /// calls the same three things `run_command`, `edit_file` and `write_to_file`, so
    /// its tools are asked about under the Claude name rather than making a person
    /// keep two lists in step. Anything without an equivalent is passed through
    /// untranslated and can be named literally.
    static func matcherName(for tool: String, provider: Provider) -> String {
        guard provider == .gemini else { return tool }
        switch tool {
        case "run_command", "shell_exec", "send_command_input": return "Bash"
        case "edit_file", "propose_code", "file_change", "replace_file_content": return "Edit"
        case "write_to_file", "write_blob", "create_file": return "Write"
        case "edit_notebook": return "NotebookEdit"
        case "read_url_content", "open_browser_url": return "WebFetch"
        default: return tool
        }
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

        // Applied after the record, so a line that both opens a session and names
        // its model lands on the row the record just created. Never creates a row
        // itself: a model says which model a session would use, not that one exists.
        defer {
            if let model = update.model {
                self.update(id) { $0.model = model }
            }
        }

        guard let record = update.record else { return }
        switch record {
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
            codexHookQuestions[id] = nil
            self.update(id) { $0.activity = .done }
        case let .activity(what):
            codexQuestions[id] = nil
            insertIfNeeded(id, provider: .openAI, directory: update.workingDirectory)
            self.update(id) { $0.activity = .running(what) }
        case let .question(question):
            insertIfNeeded(id, provider: .openAI, directory: update.workingDirectory)
            // The hook already put this question on screen, and Codex writes the call
            // into its transcript either way — including after the card was answered
            // and taken down. Without this the watcher raises the same question a
            // second time, moments after it was dealt with, which is exactly what
            // "I answered it and it asked again" looks like from the outside.
            guard !codexHookQuestions[id, default: []].contains(question) else { break }
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
            // The first request after an auto-approved plan is where the promise is
            // actually kept. `ExitPlanMode` has finished by now and has already set
            // the session's mode, so this switch is the first one that is not
            // immediately overwritten.
            //
            // Cleared on the attempt rather than on success: a build that never sends
            // this event should cost one terminal prompt, not a session that defers
            // every edit forever waiting for a switch it will never get to send.
            if case let .owed(mode) = modeHandovers[sessionID] {
                modeHandovers[sessionID] = .sent(mode)
                Log.hooks.info("""
                    switching \(sessionID, privacy: .public) to \(mode, privacy: .public)
                    """)
                return (
                    .init(decision: .allow, updatedPermissionMode: mode),
                    "Auto-approved by the plan you accepted"
                )
            }

            // The backstop for the `PreToolUse` route above: it runs when that event
            // decided nothing, and stands down when it already did.
            guard tool == "ExitPlanMode" else { return (.noOpinion, nil) }
            let plan = event.toolInput?.string("plan") ?? ""
            guard plansShown[sessionID] != plan else { return (.noOpinion, nil) }
            plansShown[sessionID] = plan
            autoApprovedPlans.remove(sessionID)
            modeHandovers[sessionID] = nil
            editsDeferredForSwitch[sessionID] = nil
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
            let terminal = TerminalDiscovery.cli(named: "codex", in: directory)
            await MainActor.run { [weak self] in
                guard let self, let terminal,
                      let index = self.sessions.firstIndex(where: { $0.id == id }),
                      self.sessions[index].terminal == nil else { return }
                self.sessions[index].terminal = terminal
                self.coalesceSessions(preferredID: id)
            }
        }
    }

    /// Adds the agents that were already running when the app launched. Anything a
    /// hook already told us about — by id, or by being the same process in the same
    /// terminal under a new id — is left alone: a hook-fed row is live and can be
    /// answered, and this one could only ever be neither.
    func adopt(_ adopted: [AdoptedSession]) {
        // The answer to "why is my session not in the list?" — said once, at launch,
        // naming the CLIs rather than the projects.
        Log.hooks.info("""
            adopting \(adopted.count) session(s) already running: \
            \(adopted.map { $0.provider.title }.sorted().joined(separator: ", "), privacy: .public)
            """)
        for candidate in adopted where !isKnown(candidate) {
            sessions.append(AgentSession(
                id: candidate.sessionID,
                provider: candidate.provider,
                project: (candidate.directory as NSString).lastPathComponent,
                lastPrompt: candidate.lastPrompt,
                model: candidate.model,
                // Between turns is the only state a transcript can prove: it is
                // written as work happens, so nothing is being waited on.
                activity: .done,
                terminal: candidate.terminal,
                isAdopted: true,
                startedAt: candidate.startedAt,
                lastEventAt: candidate.lastEventAt
            ))
        }
        reorder()
    }

    private func isKnown(_ candidate: AdoptedSession) -> Bool {
        sessions.contains {
            if $0.id == candidate.sessionID { return true }
            guard let identity = candidate.terminal.stableIdentity else { return false }
            return $0.terminal?.stableIdentity == identity
        }
    }

    func selectDestination(_ destination: TerminalDestination, for sessionID: String) {
        update(sessionID) { $0.selectedDestination = destination }
    }

    func removeSession(_ sessionID: String) {
        resolvePending(sessionID: sessionID, tool: nil)
        sessions.removeAll { $0.id == sessionID }
        codexQuestions[sessionID] = nil
        codexHookQuestions[sessionID] = nil
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
        guard request.isResolved else { return }
        if automatic {
            autoApprovedPlans.insert(request.sessionID)
            modeHandovers[request.sessionID] = .owed(PermissionMode.autoApprove)
            editsDeferredForSwitch[request.sessionID] = 0
        }
        Log.hooks.info("""
            approved plan for \(request.sessionID, privacy: .public) \
            \(automatic ? "with auto-accepted edits" : "with edits still asking", privacy: .public)
            """)
        removeResolved(request)
    }

    func requestPlanChanges(_ request: PendingRequest, feedback: String) {
        request.requestPlanChanges(feedback)
        removeResolved(request)
    }

    /// Whether this session is running under a plan the person auto-approved. Read by
    /// the row, so a session answering its own edits says so rather than looking idle.
    func isAutoApproved(sessionID: String) -> Bool {
        autoApprovedPlans.contains(sessionID)
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
            // Whatever this row was found by, it is talking to us now.
            sessions[index].isAdopted = false
            // The terminal is re-sent on every event, which is what keeps a session
            // resumed in a different window pointing at the right one.
            if !terminal.pids.isEmpty { sessions[index].terminal = terminal }
            if let directory = event.workingDirectory {
                sessions[index].project = (directory as NSString).lastPathComponent
            }
            // Antigravity sends the model on every payload; a session switched
            // mid-flight says so on its next event.
            if let model = event.model { sessions[index].model = model }
            reorder()
            // Only with a live PID in hand: the weaker pane and TTY identities are
            // for restored Codex rows, and a hook-fed session that fell back to one
            // of those could swallow a genuinely separate agent in the same pane.
            if terminal.agentPID != nil { coalesceSessions(preferredID: id) }
            return
        }
        sessions.insert(
            AgentSession(
                id: id,
                provider: event.provider,
                project: event.workingDirectory.map { ($0 as NSString).lastPathComponent },
                lastPrompt: event.prompt,
                model: event.model,
                activity: .starting,
                terminal: terminal,
                startedAt: .now,
                lastEventAt: .now
            ),
            at: 0
        )
        if terminal.agentPID != nil { coalesceSessions(preferredID: id) }
    }

    /// Coalesces only exact runtime identities. Matching titles or projects are
    /// intentionally irrelevant: two agents doing the same work in separate panes
    /// are two sessions and both remain visible. What this does catch is one agent
    /// that changed session id in place — a resume, or `/clear` — which would
    /// otherwise leave its previous row on screen for as long as the panel is open.
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
