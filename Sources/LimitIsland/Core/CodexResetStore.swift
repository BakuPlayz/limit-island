import Foundation

/// Polls willcodexquotareset.com and decides whether it is worth telling anyone.
///
/// The forecast is only actionable near the top of its range: below the threshold
/// there is nothing to do about it, so nothing is shown. Above it the point is
/// timing — tokens that survive a reset are tokens that were never spent.
@MainActor
@Observable
final class CodexResetStore {
    /// The site's own alert level, and the one asked for here.
    static let promptThreshold = 70

    private(set) var forecast: CodexResetForecast?

    /// The banner occupies a row, so the window has to be re-sized when it appears
    /// or goes away. SwiftUI re-renders itself from `forecast`; the panel's frame is
    /// the controller's job, and this is how it hears about it.
    @ObservationIgnored var onChange: (() -> Void)?

    /// Which reset cycle the person has already waved away, as its `latestResetAt`.
    /// Keying on the cycle rather than a flag means the next reset re-arms the
    /// banner on its own, while the current one stays dismissed across relaunches.
    private var dismissedResetAt: String?

    private enum DefaultsKey {
        static let forecast = "limit-island.codex-reset-forecast"
        static let dismissed = "limit-island.codex-reset-dismissed"
    }

    private static let endpoint = URL(string: "https://www.willcodexquotareset.com/api/forecast")!
    static let siteURL = URL(string: "https://www.willcodexquotareset.com/")!

    private var pollTask: Task<Void, Never>?
    /// Injectable so tests get their own suite: a dismissal is persisted, and one
    /// test's dismissal must not decide what the next one sees.
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        forecast = defaults.data(forKey: DefaultsKey.forecast)
            .flatMap { try? JSONDecoder().decode(CodexResetForecast.self, from: $0) }
        dismissedResetAt = defaults.string(forKey: DefaultsKey.dismissed)
    }

    // MARK: - Lifecycle

    func start() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                guard !Task.isCancelled else { return }
                let interval = self?.nextInterval ?? 1_800
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    func stop() {
        pollTask?.cancel()
    }

    /// A request suspended with the machine comes back to a stale clock and a dead
    /// connection. Start the cadence over rather than waiting out the old sleep.
    func refreshAfterWake() {
        start()
    }

    /// The API publishes when it will next recompute, so follow it rather than
    /// guessing. Clamped because a bad or absent value must not turn into either a
    /// hot loop or a poll that never happens again.
    private var nextInterval: TimeInterval {
        guard let next = forecast?.nextRefreshAt else { return 1_800 }
        return min(3_600, max(600, next.timeIntervalSinceNow))
    }

    private func refresh() async {
        var request = URLRequest(url: Self.endpoint)
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("LimitIsland (macOS)", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw ReadError.malformed }
            guard (200..<300).contains(http.statusCode) else { throw ReadError.http(http.statusCode) }
            let decoded = try JSONDecoder().decode(CodexForecastResponse.self, from: data)
            let changed = decoded.forecast != forecast
            forecast = decoded.forecast
            persist()
            if changed { onChange?() }
        } catch {
            // Keep the last good forecast, exactly as a failed quota read does. A
            // number half an hour old is still worth more than an empty panel, and
            // this one changes over days.
            Log.window.error("codex reset forecast unavailable: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Presentation

    /// Whether the banner belongs on screen. One method, because the panel and the
    /// window controller that sizes it must never disagree about that.
    func shouldPrompt(hasCodexAccount: Bool) -> Bool {
        guard hasCodexAccount, let forecast else { return false }
        guard forecast.score >= Self.promptThreshold else { return false }
        return forecast.cycle != dismissedResetAt
    }

    func dismiss() {
        dismissedResetAt = forecast?.cycle
        defaults.set(dismissedResetAt, forKey: DefaultsKey.dismissed)
        onChange?()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(forecast) else { return }
        defaults.set(data, forKey: DefaultsKey.forecast)
    }

    // MARK: - Testing

    /// Tests drive the presentation rules without a network. Nothing else sets a
    /// forecast by hand.
    func setForecastForTesting(_ forecast: CodexResetForecast?) {
        self.forecast = forecast
    }
}
