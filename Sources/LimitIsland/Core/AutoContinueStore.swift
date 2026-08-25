import Foundation

/// One armed promise to put a prompt back into a Claude session once its five-hour
/// window has come back.
///
/// The terminal is stored alongside the session id because the id alone stops being
/// enough the moment the app restarts: sessions are rebuilt from transcripts at
/// launch and can come back under a new id, while the pane, socket or tty the agent
/// is sitting in stays put.
struct ScheduledContinue: Codable, Equatable {
    let sessionID: String
    let project: String?
    let terminal: TerminalRef
    let message: String
    /// When to type it — one minute past the reset, not the reset itself.
    let fireAt: Date
    /// The window this belongs to. Doubles as the cycle key, so a schedule armed for
    /// one reset can never be mistaken for the next one.
    let resetAt: Date
}

/// Holds at most one scheduled continuation, fires it, and remembers what happened.
///
/// Shaped like `CodexResetStore` on purpose: same `@Observable` class, same injectable
/// defaults, same `onChange` hook for the window frame, and the same trick of keying a
/// dismissal on the cycle rather than a flag, so waving the offer away this afternoon
/// does not silence it forever.
@MainActor
@Observable
final class AutoContinueStore {
    /// Claude's own reset is not instant to the second, and a prompt typed into a
    /// window that has not actually reopened just burns the turn on an error.
    static let delayAfterReset: TimeInterval = 60

    /// What the person gets if they do not want to write anything. Deliberately
    /// plain: it has to read sensibly hours later, in a conversation nobody
    /// remembers the end of.
    static let defaultMessage = "Continue where you left off."

    /// How the last armed continuation ended. Kept until the next one is armed, so a
    /// failure is never mistaken for a quiet success.
    enum Outcome: Equatable {
        case sent(project: String?)
        case sessionGone
        case sendFailed
    }

    private(set) var scheduled: ScheduledContinue?
    private(set) var lastOutcome: Outcome?

    /// The card occupies rows the panel has to be sized for. SwiftUI re-renders
    /// itself from the observed properties; the frame is the controller's job.
    @ObservationIgnored var onChange: (() -> Void)?

    /// Which reset the person has already waved the offer away for.
    private var dismissedResetAt: Date?

    private enum DefaultsKey {
        static let scheduled = "limit-island.auto-continue"
        static let dismissed = "limit-island.auto-continue-dismissed"
    }

    private var fireTask: Task<Void, Never>?
    private var deliver: ((ScheduledContinue) async -> Outcome)?
    /// Injectable so tests get their own suite: a schedule is persisted, and one
    /// test's schedule must not decide what the next one sees.
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        scheduled = defaults.data(forKey: DefaultsKey.scheduled)
            .flatMap { try? JSONDecoder().decode(ScheduledContinue.self, from: $0) }
        dismissedResetAt = defaults.object(forKey: DefaultsKey.dismissed) as? Date
    }

    // MARK: - Lifecycle

    /// Arms the timer. `deliver` is retained for the app's lifetime because a
    /// schedule can also be armed later, from the card.
    func start(deliver: @escaping (ScheduledContinue) async -> Outcome) {
        self.deliver = deliver
        armTimer()
    }

    func stop() {
        fireTask?.cancel()
        fireTask = nil
    }

    /// A machine asleep through the reset comes back with the sleep already overdue.
    /// Re-arming re-reads the clock, and a `fireAt` now in the past fires at once.
    func refreshAfterWake() {
        armTimer()
    }

    private func armTimer() {
        fireTask?.cancel()
        guard let plan = scheduled else { return }
        fireTask = Task { [weak self] in
            // Slept in slices rather than one long sleep: a suspended machine does
            // not advance a pending `Task.sleep` predictably, and waking to find the
            // deadline hours gone is the ordinary case for a five-hour window.
            while !Task.isCancelled {
                let remaining = plan.fireAt.timeIntervalSinceNow
                guard remaining > 0 else { break }
                try? await Task.sleep(for: .seconds(min(remaining, 300)))
            }
            guard !Task.isCancelled else { return }
            await self?.fire(plan)
        }
    }

    private func fire(_ plan: ScheduledContinue) async {
        // The schedule is cleared before delivering, not after: sending takes
        // seconds and involves another process, and a schedule still on disk during
        // that window is one that could fire twice.
        scheduled = nil
        persist()
        let outcome = await deliver?(plan) ?? .sessionGone
        lastOutcome = outcome
        onChange?()
    }

    // MARK: - Presentation

    /// Whether the offer belongs on screen. One method, because the panel and the
    /// window controller that sizes it must never disagree about that.
    func shouldOffer(drainedResetAt: Date?, hasClaudeSession: Bool) -> Bool {
        guard hasClaudeSession, let drainedResetAt else { return false }
        guard scheduled == nil else { return false }
        return dismissedResetAt != drainedResetAt
    }

    func dismiss(resetAt: Date) {
        dismissedResetAt = resetAt
        defaults.set(resetAt, forKey: DefaultsKey.dismissed)
        onChange?()
    }

    func schedule(_ plan: ScheduledContinue) {
        scheduled = plan
        lastOutcome = nil
        persist()
        armTimer()
        onChange?()
    }

    func cancel() {
        stop()
        scheduled = nil
        persist()
        onChange?()
    }

    /// Clears a reported outcome once the person has seen it.
    func acknowledgeOutcome() {
        lastOutcome = nil
        onChange?()
    }

    private func persist() {
        guard let scheduled, let data = try? JSONEncoder().encode(scheduled) else {
            defaults.removeObject(forKey: DefaultsKey.scheduled)
            return
        }
        defaults.set(data, forKey: DefaultsKey.scheduled)
    }
}
