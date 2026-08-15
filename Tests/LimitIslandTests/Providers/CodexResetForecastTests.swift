import Foundation
import Testing
@testable import LimitIsland

@Suite("Codex reset forecast")
struct CodexResetForecastTests {
    /// Trimmed from a live `/api/forecast` response: the fields the app reads, with
    /// the two date shapes the payload really mixes.
    private let payload = """
    {
      "fetchedAt": "2026-08-15T14:25:56.295Z",
      "nextRefreshAt": "2026-08-15T14:55:56.295Z",
      "incidents": [{"id": "x", "status": "resolved"}],
      "forecast": {
        "aggregateAssessment": null,
        "breakdown": [
          {"label": "baseline", "points": 12},
          {"label": "OpenAI event hint", "points": 10},
          {"label": "time since last reset", "points": 1}
        ],
        "daysSinceReset": 2,
        "hoursSinceReset": 60.40535972222222,
        "latestResetAt": "2026-08-13T02:01:37.000Z",
        "resetAnnounced": false,
        "score": 23
      }
    }
    """

    private func decode(_ json: String) throws -> CodexResetForecast {
        try JSONDecoder().decode(CodexForecastResponse.self, from: Data(json.utf8)).forecast
    }

    @Test("A live payload yields the score, the buckets and both date forms")
    func decodesLivePayload() throws {
        let forecast = try decode(payload)
        #expect(forecast.score == 23)
        #expect(forecast.daysSinceReset == 2)
        #expect(forecast.latestResetAt == "2026-08-13T02:01:37.000Z")
        #expect(forecast.breakdown.count == 3)
        #expect(forecast.breakdownSummary == "baseline 12 · OpenAI event hint 10 · time since last reset 1")
        // Fractional seconds: the plain ISO-8601 formatter rejects this outright.
        #expect(forecast.nextRefreshAt != nil)
    }

    @Test("A forecast stripped to its score still decodes")
    func decodesMinimalPayload() throws {
        let forecast = try decode(#"{"forecast": {"score": 81}}"#)
        #expect(forecast.score == 81)
        #expect(forecast.breakdown.isEmpty)
        #expect(forecast.latestResetAt == nil)
        #expect(forecast.nextRefreshAt == nil)
        // Dismissal needs a key even when the payload names no reset.
        #expect(forecast.cycle == "unknown")
    }

    @MainActor
    private func store(score: Int, cycle: String? = "2026-08-13T02:01:37.000Z") -> CodexResetStore {
        // Its own defaults suite: dismissal is persisted, and these tests must not
        // read each other's - or the running app's - state.
        let store = CodexResetStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        store.setForecastForTesting(
            CodexResetForecast(
                score: score, daysSinceReset: 3, latestResetAt: cycle,
                breakdown: [], nextRefreshAt: nil
            )
        )
        return store
    }

    @MainActor
    @Test("The banner starts exactly at the threshold, and only for a Codex account")
    func promptsAtThreshold() {
        #expect(store(score: 69).shouldPrompt(hasCodexAccount: true) == false)
        #expect(store(score: 70).shouldPrompt(hasCodexAccount: true))
        #expect(store(score: 78).shouldPrompt(hasCodexAccount: false) == false)
        let empty = CodexResetStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        #expect(empty.shouldPrompt(hasCodexAccount: true) == false)
    }

    @MainActor
    @Test("Dismissing covers this reset cycle, and the next one re-arms it")
    func dismissalIsPerCycle() {
        let store = store(score: 78)
        store.dismiss()
        #expect(store.shouldPrompt(hasCodexAccount: true) == false)

        // A later forecast naming a newer reset is a new cycle, not the one waved away.
        store.setForecastForTesting(
            CodexResetForecast(
                score: 78, daysSinceReset: 0, latestResetAt: "2026-08-20T09:00:00.000Z",
                breakdown: [], nextRefreshAt: nil
            )
        )
        #expect(store.shouldPrompt(hasCodexAccount: true))
    }
}
