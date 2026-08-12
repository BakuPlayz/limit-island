import Foundation

// MARK: - Tolerant decoding

/// Lets a decoder look up keys by name at runtime.
struct DynamicKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

extension KeyedDecodingContainer where Key == DynamicKey {
    /// First of `names` that is present and reads as a number. Providers send
    /// percentages as both JSON numbers and quoted strings.
    func number(_ names: String...) -> Double? {
        for name in names {
            let key = DynamicKey(stringValue: name)
            if let value = try? decodeIfPresent(Double.self, forKey: key) { return value }
            if let text = try? decodeIfPresent(String.self, forKey: key), let value = Double(text) { return value }
        }
        return nil
    }

    func string(_ names: String...) -> String? {
        for name in names {
            if let value = try? decodeIfPresent(String.self, forKey: DynamicKey(stringValue: name)),
               !value.isEmpty { return value }
        }
        return nil
    }

    /// An identifier that may be quoted or numeric. Declaring one of these as a
    /// plain `String?` is enough to fail the whole surrounding object.
    func identifier(_ names: String...) -> String? {
        for name in names {
            let key = DynamicKey(stringValue: name)
            if let text = try? decodeIfPresent(String.self, forKey: key), !text.isEmpty { return text }
            if let number = try? decodeIfPresent(Int.self, forKey: key) { return String(number) }
        }
        return nil
    }

    func strings(_ name: String) -> [String] {
        (try? decodeIfPresent([String].self, forKey: DynamicKey(stringValue: name))) ?? []
    }

    /// When a window resets. Kept tolerant rather than bound to one spelling —
    /// the three providers disagree on the key, and Codex sends an absolute
    /// timestamp and a relative offset side by side.
    func resetDate() -> Date? {
        for name in ResetDateParser.absoluteKeys {
            let key = DynamicKey(stringValue: name)
            if let seconds = try? decodeIfPresent(Double.self, forKey: key) {
                return ResetDateParser.date(fromEpoch: seconds)
            }
            if let text = try? decodeIfPresent(String.self, forKey: key),
               let date = ResetDateParser.date(fromText: text) {
                return date
            }
        }
        for name in ResetDateParser.relativeKeys {
            if let seconds = try? decodeIfPresent(Double.self, forKey: DynamicKey(stringValue: name)) {
                return Date(timeIntervalSinceNow: seconds)
            }
        }
        return nil
    }
}

enum ResetDateParser {
    static let absoluteKeys = ["resets_at", "reset_at", "resetAt", "reset_time", "resetTime"]
    static let relativeKeys = ["reset_after_seconds", "resets_in_seconds", "reset_in_seconds"]

    /// Constructing an `ISO8601DateFormatter` is expensive, and the default one
    /// rejects fractional seconds — which is the form claude.ai returns, and the
    /// reason Claude never produced a reset date at all.
    ///
    /// `nonisolated(unsafe)` because `ISO8601DateFormatter` is not `Sendable`,
    /// but these two are configured once here and only ever read from afterwards,
    /// and parsing is thread-safe.
    nonisolated(unsafe) static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    nonisolated(unsafe) static let plain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// APIs normally return Unix seconds; tolerate millisecond values.
    static func date(fromEpoch seconds: Double) -> Date {
        Date(timeIntervalSince1970: seconds > 10_000_000_000 ? seconds / 1000 : seconds)
    }

    static func date(fromText text: String) -> Date? {
        if let date = fractional.date(from: text) { return date }
        if let date = plain.date(from: text) { return date }
        if let seconds = Double(text) { return date(fromEpoch: seconds) }
        return nil
    }
}

private func clamp(_ value: Double) -> Double { min(100, max(0, value)) }

/// Describes the structure of a JSON payload — key names and value *types* only,
/// never values — so a decode failure says which part of the shape moved.
///
/// These responses carry account data, so nothing that could be personal is
/// logged: an unexpected shape is diagnosed from its skeleton.
enum JSONShape {
    /// Depth 3 is what these payloads need: an envelope, an array, and the object
    /// whose field types are the thing actually in question.
    static func describe(_ data: Data, depth: Int = 3) -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return "not json (\(data.count) bytes)"
        }
        return describe(json, depth: depth)
    }

    static func describe(_ value: Any, depth: Int) -> String {
        switch value {
        case let dictionary as [String: Any]:
            guard depth > 0 else { return "{…}" }
            let keys = dictionary.keys.sorted().prefix(12)
            let fields = keys.map { "\($0): \(describe(dictionary[$0]!, depth: depth - 1))" }
            let more = dictionary.count > keys.count ? ", +\(dictionary.count - keys.count) more" : ""
            return "{\(fields.joined(separator: ", "))\(more)}"
        case let array as [Any]:
            guard depth > 0, let first = array.first else { return "[\(array.count)]" }
            return "[\(array.count) × \(describe(first, depth: depth - 1))]"
        case is String: return "string"
        case is NSNull: return "null"
        case let number as NSNumber:
            return CFGetTypeID(number) == CFBooleanGetTypeID() ? "bool" : "number"
        default: return "?"
        }
    }
}

// MARK: - Codex

struct CodexUsageResponse: Decodable {
    struct Window: Decodable {
        let usedPercent: Double?
        let limitWindowSeconds: Int?
        let resetAt: Date?

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: DynamicKey.self)
            usedPercent = container.number("used_percent", "usedPercent")
            limitWindowSeconds = container.number("limit_window_seconds", "limitWindowSeconds").map(Int.init)
            resetAt = container.resetDate()
        }

        var remaining: Double? { usedPercent.map { clamp(100 - $0) } }
    }

    let windows: [Window]
    let email: String?
    let planType: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicKey.self)
        email = container.string("email")
        planType = container.string("plan_type", "planType")
        let rateLimit = try? container.nestedContainer(
            keyedBy: DynamicKey.self,
            forKey: DynamicKey(stringValue: "rate_limit")
        )
        windows = ["primary_window", "secondary_window"].compactMap { name in
            try? rateLimit?.decodeIfPresent(Window.self, forKey: DynamicKey(stringValue: name))
        }
    }

    /// Matched strictly on window length. Positional fallbacks used to relabel
    /// the weekly window as five-hour on plans that only have one, producing two
    /// identical readings.
    var usage: SubscriptionUsage? {
        let fiveHour = windows.first { $0.limitWindowSeconds == 18_000 }
        let week = windows.first { $0.limitWindowSeconds == 604_800 }
        guard fiveHour?.remaining != nil || week?.remaining != nil else { return nil }
        return SubscriptionUsage(
            provider: .openAI,
            fiveHourRemaining: fiveHour?.remaining,
            weekRemaining: week?.remaining,
            fiveHourResetAt: fiveHour?.resetAt,
            weekResetAt: week?.resetAt,
            updatedAt: .now,
            status: .ready
        )
    }

    var identity: String? {
        guard let email else { return nil }
        guard let planType else { return email }
        return "\(email) (\(planType))"
    }
}

// MARK: - Claude

struct ClaudeUsageResponse: Decodable {
    struct Window: Decodable {
        let utilization: Double?
        let resetAt: Date?

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: DynamicKey.self)
            utilization = container.number("utilization")
            resetAt = container.resetDate()
        }

        /// Claude has reported utilization on both a 0–1 and a 0–100 scale.
        var remaining: Double? {
            utilization.map { clamp(100 - ($0 <= 1 ? $0 * 100 : $0)) }
        }
    }

    let fiveHour: Window?
    let sevenDay: Window?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicKey.self)
        fiveHour = try? container.decodeIfPresent(Window.self, forKey: DynamicKey(stringValue: "five_hour"))
        sevenDay = try? container.decodeIfPresent(Window.self, forKey: DynamicKey(stringValue: "seven_day"))
    }

    var usage: SubscriptionUsage? {
        guard fiveHour?.remaining != nil || sevenDay?.remaining != nil else { return nil }
        return SubscriptionUsage(
            provider: .claude,
            fiveHourRemaining: fiveHour?.remaining,
            weekRemaining: sevenDay?.remaining,
            fiveHourResetAt: fiveHour?.resetAt,
            weekResetAt: sevenDay?.resetAt,
            updatedAt: .now,
            status: .ready
        )
    }
}

/// `/api/organizations` answers with a bare array on some accounts and a
/// `{ "data": [...] }` envelope on others, and each entry carries around thirty
/// fields this app has no interest in.
///
/// Every field is therefore read defensively. Declaring an id as a plain
/// `String?` was enough to fail the entire response when one arrived numeric,
/// which silently pushed Claude onto the page scraper on every refresh.
struct ClaudeOrganizations: Decodable {
    struct Organization: Decodable {
        let uuid: String?
        let name: String?
        let capabilities: [String]

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: DynamicKey.self)
            uuid = container.identifier("uuid", "id", "organization_uuid")
            name = container.string("name", "display_name")
            capabilities = container.strings("capabilities")
        }
    }

    let organizations: [Organization]

    init(from decoder: Decoder) throws {
        if let values = try? decoder.singleValueContainer().decode([Failable<Organization>].self) {
            organizations = values.compactMap(\.value)
            return
        }
        if let container = try? decoder.container(keyedBy: DynamicKey.self) {
            for key in ["data", "organizations", "results"] {
                if let values = try? container.decode([Failable<Organization>].self, forKey: DynamicKey(stringValue: key)) {
                    organizations = values.compactMap(\.value)
                    return
                }
            }
        }
        organizations = []
    }

    /// An account can belong to several organizations. The one backing claude.ai
    /// is the one with the chat capability; anything else is an API-only org with
    /// no subscription usage to report.
    var subscription: Organization? {
        organizations.first { $0.capabilities.contains("chat") } ?? organizations.first
    }

    var identifier: String? { subscription?.uuid }
    var name: String? { subscription?.name }
}

/// Decodes an element, or nothing, so one unexpected entry cannot fail a whole
/// list. These provider payloads are undocumented and grow fields without notice.
struct Failable<Value: Decodable>: Decodable {
    let value: Value?
    init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
}

// MARK: - Gemini

/// `v1internal:loadCodeAssist`. The only field that matters is the project the
/// quota is billed against — the CLI never persists it, so it has to be asked
/// for on every launch.
struct LoadCodeAssistResponse: Decodable {
    let cloudaicompanionProject: String?
}

/// `v1internal:retrieveUserQuota`.
struct GeminiQuotaResponse: Decodable {
    struct Bucket: Decodable {
        let modelId: String?
        let remainingFraction: Double
        let resetAt: Date?

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: DynamicKey.self)
            modelId = container.string("modelId", "model_id")
            guard let fraction = container.number("remainingFraction", "remaining_fraction") else {
                throw DecodingError.keyNotFound(
                    DynamicKey(stringValue: "remainingFraction"),
                    .init(codingPath: decoder.codingPath, debugDescription: "bucket has no remainingFraction")
                )
            }
            remainingFraction = fraction
            resetAt = container.resetDate()
        }
    }

    let buckets: [Bucket]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicKey.self)
        let raw = (try? container.decode([Failable<Bucket>].self, forKey: DynamicKey(stringValue: "buckets"))) ?? []
        buckets = raw.compactMap(\.value)
    }

    /// Gemini reports a pool per model rather than five-hour and weekly windows.
    /// The scarcest bucket is the one that will actually block you, so it is the
    /// one shown — which is also how the CLI picks the number in its own footer.
    var usage: SubscriptionUsage? {
        guard let tightest = buckets.min(by: { $0.remainingFraction < $1.remainingFraction }) else { return nil }
        return SubscriptionUsage(
            provider: .gemini,
            fiveHourRemaining: clamp(tightest.remainingFraction * 100),
            weekRemaining: nil,
            fiveHourResetAt: tightest.resetAt,
            weekResetAt: nil,
            updatedAt: .now,
            status: .ready
        )
    }

}

/// `v1internal:retrieveUserQuotaSummary`. Unlike the model buckets returned by
/// `retrieveUserQuota`, this groups the Gemini pool into its five-hour and
/// weekly limits.
struct GeminiQuotaSummaryResponse: Decodable {
    struct Bucket: Decodable {
        let label: String
        let remainingFraction: Double?
        let resetAt: Date?

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: DynamicKey.self)
            label = [
                container.string("displayName", "display_name"),
                container.string("bucketId", "bucket_id", "name"),
                container.string("description")
            ].compactMap { $0 }.joined(separator: " ")

            if let fraction = container.number("remainingFraction", "remaining_fraction") {
                remainingFraction = fraction
                resetAt = container.resetDate()
            } else if let remaining = try? container.nestedContainer(keyedBy: DynamicKey.self, forKey: DynamicKey(stringValue: "remaining")) {
                remainingFraction = remaining.number("remainingFraction", "remaining_fraction")
                resetAt = remaining.resetDate() ?? container.resetDate()
            } else {
                remainingFraction = nil
                resetAt = container.resetDate()
            }
        }
    }

    struct Group: Decodable {
        let label: String
        let buckets: [Bucket]

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: DynamicKey.self)
            label = container.string("displayName", "display_name", "groupName", "group_name", "name") ?? ""
            let raw = (try? container.decode([Failable<Bucket>].self, forKey: DynamicKey(stringValue: "buckets"))) ?? []
            buckets = raw.compactMap(\.value)
        }
    }

    let groups: [Group]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicKey.self)
        var raw = (try? container.decode([Failable<Group>].self, forKey: DynamicKey(stringValue: "groups"))) ?? []
        // Some clients wrap the same groups in `quotaSummary`.
        if raw.isEmpty,
           let summary = try? container.nestedContainer(keyedBy: DynamicKey.self, forKey: DynamicKey(stringValue: "quotaSummary")) {
            raw = (try? summary.decode([Failable<Group>].self, forKey: DynamicKey(stringValue: "groups"))) ?? []
        }
        groups = raw.compactMap(\.value)
    }

    var usage: SubscriptionUsage? {
        // Ignore other model families (for example Claude + GPT) when a richer
        // response is returned for the same Google account.
        let buckets = groups
            .filter { $0.label.localizedCaseInsensitiveContains("gemini") }
            .flatMap(\.buckets)
        guard !buckets.isEmpty else { return nil }

        let weekly = buckets.filter { $0.label.localizedCaseInsensitiveContains("week") }
        let short = buckets.filter { !$0.label.localizedCaseInsensitiveContains("week") }
        let fiveHour = short.min { ($0.remainingFraction ?? 1) < ($1.remainingFraction ?? 1) }
        let week = weekly.min { ($0.remainingFraction ?? 1) < ($1.remainingFraction ?? 1) }

        guard fiveHour?.remainingFraction != nil || week?.remainingFraction != nil else { return nil }
        return SubscriptionUsage(
            provider: .gemini,
            fiveHourRemaining: fiveHour.map { clamp(($0.remainingFraction ?? 0) * 100) },
            weekRemaining: week.map { clamp(($0.remainingFraction ?? 0) * 100) },
            fiveHourResetAt: fiveHour?.resetAt,
            weekResetAt: week?.resetAt,
            updatedAt: .now,
            status: .ready
        )
    }
}

struct GoogleUserInfo: Decodable {
    let email: String?
}

// MARK: - Page scraping

/// Last-resort reader for providers with no usable API. Genuinely approximate:
/// it reads whatever the usage page happens to render.
enum SubscriptionTextParser {
    static func percentages(from pageText: String) -> (fiveHour: Double?, week: Double?) {
        let text = pageText.lowercased()
        return (
            percentage(near: ["5 hour", "5-hour", "five hour", "5h"], in: text),
            percentage(near: ["weekly", "week"], in: text)
        )
    }

    static func percentage(near labels: [String], in text: String) -> Double? {
        // Earliest match in the document, not the first label in the array —
        // otherwise "5 hour" appearing late outranks "5h" appearing first.
        guard let labelRange = labels.compactMap({ text.range(of: $0) }).min(by: { $0.lowerBound < $1.lowerBound })
        else { return nil }
        let start = text.index(labelRange.lowerBound, offsetBy: -90, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(labelRange.upperBound, offsetBy: 150, limitedBy: text.endIndex) ?? text.endIndex
        let excerpt = String(text[start..<end])

        if let fraction = match("(\\d{1,6})\\s*(?:/|of)\\s*(\\d{1,6})", in: excerpt),
           let used = Double(fraction.groups[0]), let total = Double(fraction.groups[1]), total > 0 {
            return clamp(100 - used / total * 100)
        }
        guard let percent = match("(\\d{1,3}(?:\\.\\d+)?)\\s*%", in: excerpt),
              let value = Double(percent.groups[0]) else { return nil }
        return clamp(describesConsumption(around: percent.range, in: excerpt) ? 100 - value : value)
    }

    private static let consumptionWords = ["used", "consumed", "spent"]
    private static let remainderWords = ["remaining", "left", "available"]

    /// Whether the number counts what has been spent rather than what is left.
    ///
    /// "used" occurs on essentially every usage page, including in a sentence
    /// well away from a *remaining* percentage, so mere presence is not evidence.
    /// Whichever kind of word sits closest to the number is the one describing it.
    private static func describesConsumption(around range: Range<String.Index>, in excerpt: String) -> Bool {
        guard let consumed = distance(from: range, toNearestOf: consumptionWords, in: excerpt) else { return false }
        guard let remaining = distance(from: range, toNearestOf: remainderWords, in: excerpt) else { return true }
        return consumed < remaining
    }

    private static func distance(
        from range: Range<String.Index>,
        toNearestOf words: [String],
        in excerpt: String
    ) -> Int? {
        words.compactMap { word -> Int? in
            var best: Int?
            var searchStart = excerpt.startIndex
            while let found = excerpt.range(of: word, range: searchStart..<excerpt.endIndex) {
                let gap = found.lowerBound >= range.upperBound
                    ? excerpt.distance(from: range.upperBound, to: found.lowerBound)
                    : excerpt.distance(from: found.upperBound, to: range.lowerBound)
                best = min(best ?? gap, max(0, gap))
                searchStart = found.upperBound
            }
            return best
        }.min()
    }

    private static func match(_ pattern: String, in text: String) -> (groups: [String], range: Range<String.Index>)? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let result = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let full = Range(result.range, in: text) else { return nil }
        let groups = (1..<result.numberOfRanges).compactMap {
            Range(result.range(at: $0), in: text).map { String(text[$0]) }
        }
        return (groups, full)
    }
}
