import Foundation

/// The chance OpenAI hands out an unexpected Codex quota reset in the next 48 hours,
/// as forecast by willcodexquotareset.com.
///
/// Their own words: "weather, but for tokens". It is a guess assembled from public
/// incidents, posts and the time since the last reset, and the app presents it as one
/// — the value of knowing is that unspent tokens are about to be worthless, not that
/// anything has been promised.
struct CodexResetForecast: Equatable, Codable {
    /// 0–100, the percentage the site puts on its gauge.
    var score: Int
    var daysSinceReset: Int?
    /// Kept as the raw string it arrived as. This is only ever an identity — which
    /// reset cycle a dismissal belongs to — and never a date to do arithmetic with.
    var latestResetAt: String?
    /// The buckets the score was summed from, shown as the banner's tooltip so the
    /// number can be inspected rather than taken on faith.
    var breakdown: [Bucket]
    /// When the API says it will next recompute. It refreshes about every half hour
    /// and there is nothing to gain by asking more often than it changes.
    var nextRefreshAt: Date?

    struct Bucket: Equatable, Codable {
        var label: String
        var points: Int
    }

    /// Identifies the reset cycle this forecast belongs to, for a dismissal to be
    /// keyed on. A payload without `latestResetAt` still needs a stable key, or
    /// dismissing the banner would never stick.
    var cycle: String { latestResetAt ?? "unknown" }

    /// `baseline 12 · OpenAI event hint 10 · time since last reset 1`
    var breakdownSummary: String {
        breakdown.map { "\($0.label) \($0.points)" }.joined(separator: " · ")
    }
}

/// The `/api/forecast` payload. It also carries the raw incidents, posts and reset
/// events the site renders further down its page; none of that is decoded.
struct CodexForecastResponse: Decodable {
    let forecast: CodexResetForecast

    private enum Key: String, CodingKey {
        case forecast, nextRefreshAt
    }

    private enum ForecastKey: String, CodingKey {
        case score, daysSinceReset, latestResetAt, breakdown
    }

    init(from decoder: Decoder) throws {
        let root = try decoder.container(keyedBy: Key.self)
        let body = try root.nestedContainer(keyedBy: ForecastKey.self, forKey: .forecast)
        forecast = CodexResetForecast(
            score: try body.decode(Int.self, forKey: .score),
            daysSinceReset: try body.decodeIfPresent(Int.self, forKey: .daysSinceReset),
            latestResetAt: try body.decodeIfPresent(String.self, forKey: .latestResetAt),
            breakdown: try body.decodeIfPresent([CodexResetForecast.Bucket].self, forKey: .breakdown) ?? [],
            nextRefreshAt: Self.date(
                try root.decodeIfPresent(String.self, forKey: .nextRefreshAt)
            )
        )
    }

    /// The payload mixes both ISO-8601 shapes — `nextRefreshAt` carries milliseconds
    /// and `latestResetAt` does not — which is why `JSONDecoder`'s `.iso8601`
    /// strategy cannot be used here. `ResetDateParser` already tries both.
    static func date(_ text: String?) -> Date? {
        text.flatMap(ResetDateParser.date(fromText:))
    }
}
