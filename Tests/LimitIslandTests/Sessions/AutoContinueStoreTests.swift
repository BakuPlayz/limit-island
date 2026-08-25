import Foundation
import Testing
@testable import LimitIsland

@Suite("Auto-continue after a reset")
struct AutoContinueStoreTests {
    /// Each store gets its own suite so one test's schedule cannot decide what the
    /// next one — or the running app — sees.
    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: UUID().uuidString)!
    }

    private func plan(fireAt: Date, resetAt: Date = .now.addingTimeInterval(3_600)) -> ScheduledContinue {
        ScheduledContinue(
            sessionID: "session-1",
            project: "vibe-usage",
            terminal: TerminalRef(
                program: "Apple_Terminal", tty: "/dev/ttys004",
                workingDirectory: "/tmp", agentPID: 4_242, pids: [4_242]
            ),
            message: "Continue where you left off.",
            fireAt: fireAt,
            resetAt: resetAt
        )
    }

    @MainActor
    @Test("The offer needs a drained window and a session to put the prompt into")
    func offersOnlyWhenActionable() {
        let store = AutoContinueStore(defaults: defaults())
        let resetAt = Date.now.addingTimeInterval(3_600)

        #expect(store.shouldOffer(drainedResetAt: nil, hasClaudeSession: true) == false)
        #expect(store.shouldOffer(drainedResetAt: resetAt, hasClaudeSession: false) == false)
        #expect(store.shouldOffer(drainedResetAt: resetAt, hasClaudeSession: true))
    }

    @MainActor
    @Test("An armed schedule replaces the offer rather than sitting beside it")
    func armedScheduleSuppressesTheOffer() {
        let store = AutoContinueStore(defaults: defaults())
        let resetAt = Date.now.addingTimeInterval(3_600)
        store.schedule(plan(fireAt: resetAt.addingTimeInterval(60), resetAt: resetAt))

        #expect(store.scheduled != nil)
        #expect(store.shouldOffer(drainedResetAt: resetAt, hasClaudeSession: true) == false)

        store.cancel()
        #expect(store.scheduled == nil)
        #expect(store.shouldOffer(drainedResetAt: resetAt, hasClaudeSession: true))
    }

    @MainActor
    @Test("Dismissing covers this window only, and the next reset re-arms the offer")
    func dismissalIsPerCycle() {
        let store = AutoContinueStore(defaults: defaults())
        let resetAt = Date.now.addingTimeInterval(3_600)
        store.dismiss(resetAt: resetAt)

        #expect(store.shouldOffer(drainedResetAt: resetAt, hasClaudeSession: true) == false)
        // The window after it is a different cycle, not the one waved away.
        let next = resetAt.addingTimeInterval(18_000)
        #expect(store.shouldOffer(drainedResetAt: next, hasClaudeSession: true))
    }

    @MainActor
    @Test("A schedule and a dismissal both survive a relaunch")
    func statePersists() {
        let suite = defaults()
        let resetAt = Date.now.addingTimeInterval(3_600)
        let first = AutoContinueStore(defaults: suite)
        first.dismiss(resetAt: resetAt)
        first.schedule(plan(fireAt: resetAt.addingTimeInterval(60), resetAt: resetAt))

        let second = AutoContinueStore(defaults: suite)
        #expect(second.scheduled == first.scheduled)
        #expect(second.scheduled?.message == "Continue where you left off.")
        second.cancel()
        #expect(second.shouldOffer(drainedResetAt: resetAt, hasClaudeSession: true) == false)
    }

    @MainActor
    @Test("A deadline already past fires as soon as the app is running again")
    func overdueScheduleFiresOnce() async {
        let suite = defaults()
        let overdue = plan(fireAt: .now.addingTimeInterval(-600))
        AutoContinueStore(defaults: suite).schedule(overdue)

        // A laptop closed through the reset is the ordinary case, not an edge one:
        // the store that comes back has to notice the deadline went by while it
        // was not running.
        let store = AutoContinueStore(defaults: suite)
        let delivered = Delivered()
        store.start { plan in
            await delivered.record(plan)
            return .sent(project: plan.project)
        }

        await delivered.waitForFirst()
        #expect(await delivered.count == 1)
        #expect(store.scheduled == nil)
        #expect(store.lastOutcome == .sent(project: "vibe-usage"))

        // And the schedule is off the disk, so the next launch does not repeat it.
        #expect(AutoContinueStore(defaults: suite).scheduled == nil)
    }

    /// Records what the fire path handed to delivery. An actor because the store
    /// calls it from its own task.
    private actor Delivered {
        private var plans: [ScheduledContinue] = []

        var count: Int { plans.count }

        func record(_ plan: ScheduledContinue) {
            plans.append(plan)
        }

        func waitForFirst() async {
            for _ in 0..<100 {
                if !plans.isEmpty { return }
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
    }
}

@Suite("Detecting a drained five-hour window")
struct DrainedWindowTests {
    private func usage(
        remaining: Double?, resetAt: Date?, status: SubscriptionUsage.Status = .ready
    ) -> SubscriptionUsage {
        SubscriptionUsage(
            provider: .claude, fiveHourRemaining: remaining, weekRemaining: 40,
            fiveHourResetAt: resetAt, weekResetAt: nil, updatedAt: .now, status: status
        )
    }

    private var soon: Date { .now.addingTimeInterval(3_600) }

    @Test("A spent window with a reset date is what the offer needs")
    func detectsDrainedWindow() {
        #expect(QuotaStore.drainedReset(in: usage(remaining: 1, resetAt: soon)) != nil)
        #expect(QuotaStore.drainedReset(in: usage(remaining: 0, resetAt: soon)) != nil)
    }

    @Test("A window with room left is not drained")
    func ignoresHealthyWindow() {
        #expect(QuotaStore.drainedReset(in: usage(remaining: 10, resetAt: soon)) == nil)
        #expect(QuotaStore.drainedReset(in: usage(remaining: nil, resetAt: soon)) == nil)
    }

    @Test("Without a reset date there is nothing to schedule against")
    func requiresAResetDate() {
        // The scraped fallback reads a percentage but never a reset time. Guessing
        // five hours out would arm a prompt for a window that is still empty.
        #expect(QuotaStore.drainedReset(in: usage(remaining: 1, resetAt: nil)) == nil)
        #expect(QuotaStore.drainedReset(in: usage(remaining: 1, resetAt: .now.addingTimeInterval(-60))) == nil)
    }

    @Test("A reading the app is not confident in does not arm anything")
    func requiresAReadyReading() {
        #expect(QuotaStore.drainedReset(in: usage(remaining: 1, resetAt: soon, status: .unavailable)) == nil)
    }
}
