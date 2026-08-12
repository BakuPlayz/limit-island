import Foundation
import Testing
@testable import LimitIsland

// MARK: - Codex

@Suite("Codex usage mapping")
struct CodexUsageTests {
    private func decode(_ json: String) throws -> CodexUsageResponse {
        try JSONDecoder().decode(CodexUsageResponse.self, from: Data(json.utf8))
    }

    @Test("Windows are matched on length, not position")
    func matchesWindowsByLength() throws {
        // Deliberately weekly-first: a positional fallback used to relabel the
        // weekly window as five-hour and report the same number twice.
        let response = try decode("""
        {"rate_limit":{"primary_window":{"used_percent":80,"limit_window_seconds":604800},
                       "secondary_window":{"used_percent":25,"limit_window_seconds":18000}}}
        """)
        let usage = try #require(response.usage)
        #expect(usage.fiveHourRemaining == 75)
        #expect(usage.weekRemaining == 20)
    }

    @Test("A plan with only one window leaves the other blank")
    func singleWindow() throws {
        let response = try decode("""
        {"rate_limit":{"primary_window":{"used_percent":10,"limit_window_seconds":18000}}}
        """)
        let usage = try #require(response.usage)
        #expect(usage.fiveHourRemaining == 90)
        #expect(usage.weekRemaining == nil)
    }

    @Test("No usable window yields no reading at all")
    func noWindows() throws {
        #expect(try decode(#"{"rate_limit":{}}"#).usage == nil)
        #expect(try decode(#"{}"#).usage == nil)
    }

    @Test("Used percent over 100 clamps to zero remaining")
    func clampsOverconsumption() throws {
        let response = try decode("""
        {"rate_limit":{"primary_window":{"used_percent":140,"limit_window_seconds":18000}}}
        """)
        #expect(try #require(response.usage).fiveHourRemaining == 0)
    }

    @Test("Identity combines address and plan")
    func identity() throws {
        #expect(try decode(#"{"email":"a@b.com","plan_type":"pro"}"#).identity == "a@b.com (pro)")
        #expect(try decode(#"{"email":"a@b.com"}"#).identity == "a@b.com")
        #expect(try decode(#"{"plan_type":"pro"}"#).identity == nil)
    }
}

// MARK: - Claude

@Suite("Claude usage mapping")
struct ClaudeUsageTests {
    private func decode(_ json: String) throws -> ClaudeUsageResponse {
        try JSONDecoder().decode(ClaudeUsageResponse.self, from: Data(json.utf8))
    }

    @Test("Utilization on a 0-1 scale is read as a fraction")
    func fractionalUtilization() throws {
        let usage = try #require(try decode(#"{"five_hour":{"utilization":0.25}}"#).usage)
        #expect(usage.fiveHourRemaining == 75)
    }

    @Test("Utilization above 1 is read as a percentage")
    func percentageUtilization() throws {
        let usage = try #require(try decode(#"{"seven_day":{"utilization":25}}"#).usage)
        #expect(usage.weekRemaining == 75)
    }

    @Test("Fractional-second timestamps parse")
    func fractionalSecondsResetDate() throws {
        // The default ISO8601 formatter rejects this form, which is why Claude
        // never produced a reset date before.
        let response = try decode("""
        {"five_hour":{"utilization":0.5,"resets_at":"2026-08-08T12:30:00.123Z"}}
        """)
        let reset = try #require(response.fiveHour?.resetAt)
        #expect(abs(reset.timeIntervalSince1970 - 1_786_192_200.123) < 0.01)
    }

    @Test("Organizations decode from a bare array and from a data envelope")
    func organizationEnvelopes() throws {
        let bare = try decodeOrganizations(#"[{"uuid":"abc","name":"Acme"}]"#)
        #expect(bare.identifier == "abc")
        #expect(bare.name == "Acme")

        let wrapped = try decodeOrganizations(#"{"data":[{"id":"def","name":"Other"}]}"#)
        #expect(wrapped.identifier == "def")
    }

    @Test("The thirty-odd fields Claude actually sends do not break the decode")
    func toleratesRealPayload() throws {
        // Trimmed from a live response. Every refresh was failing on this,
        // silently pushing Claude onto the page scraper.
        let organizations = try decodeOrganizations("""
        [{"uuid":"org-1","name":"Personal","capabilities":["chat","claude_pro"],
          "active_flags":[],"api_disabled_reason":null,"api_disabled_until":null,
          "billable_usage_paused_until":null,"billing_type":"stripe",
          "claude_ai_bootstrap_models_config":null,"created_at":"2025-01-01T00:00:00Z",
          "data_retention":"default","data_retention_periods":null,"external_mapping":null,
          "free_credits_status":"none","settings":{"nested":{"deep":true}}}]
        """)
        #expect(organizations.identifier == "org-1")
    }

    @Test("A numeric id does not fail the whole response")
    func toleratesNumericIdentifier() throws {
        // Declaring this as a plain String? is what broke the real payload:
        // one type mismatch inside one element failed every organization.
        let organizations = try decodeOrganizations(#"[{"id":40219,"name":"Acme"}]"#)
        #expect(organizations.identifier == "40219")
    }

    @Test("The chat organization is preferred over an API-only one")
    func picksSubscriptionOrganization() throws {
        // An account can be in several; only the chat org has subscription usage.
        let organizations = try decodeOrganizations("""
        [{"uuid":"api-org","name":"API","capabilities":["api"]},
         {"uuid":"chat-org","name":"Personal","capabilities":["chat","claude_pro"]}]
        """)
        #expect(organizations.identifier == "chat-org")
        #expect(organizations.name == "Personal")
    }

    @Test("An unrecognisable payload yields no organizations instead of throwing")
    func neverThrows() throws {
        #expect(try decodeOrganizations(#"{"error":{"type":"not_found"}}"#).identifier == nil)
        #expect(try decodeOrganizations("[]").identifier == nil)
        #expect(try decodeOrganizations(#"["not-an-object"]"#).identifier == nil)
    }

    private func decodeOrganizations(_ json: String) throws -> ClaudeOrganizations {
        try JSONDecoder().decode(ClaudeOrganizations.self, from: Data(json.utf8))
    }
}

// MARK: - Gemini

@Suite("Gemini quota mapping")
struct GeminiQuotaTests {
    private func decode(_ json: String) throws -> GeminiQuotaResponse {
        try JSONDecoder().decode(GeminiQuotaResponse.self, from: Data(json.utf8))
    }

    @Test("The scarcest bucket is the one reported")
    func picksTightestBucket() throws {
        let response = try decode("""
        {"buckets":[{"modelId":"gemini-2.5-flash","remainingFraction":0.9},
                    {"modelId":"gemini-2.5-pro","remainingFraction":0.12,"resetTime":"2026-08-08T12:00:00Z"},
                    {"modelId":"gemini-2.5-flash-lite","remainingFraction":0.55}]}
        """)
        let usage = try #require(response.usage)
        #expect(abs(usage.fiveHourRemaining! - 12) < 0.0001)
        #expect(usage.fiveHourResetAt != nil)
        // Gemini reports one pool rather than separate windows.
        #expect(usage.weekRemaining == nil)
        #expect(usage.weekResetAt == nil)
    }

    @Test("A bucket missing remainingFraction is skipped, not fatal")
    func skipsMalformedBucket() throws {
        let response = try decode("""
        {"buckets":[{"modelId":"broken"},{"modelId":"ok","remainingFraction":0.4}]}
        """)
        #expect(response.buckets.count == 1)
        #expect(abs(try #require(response.usage).fiveHourRemaining! - 40) < 0.0001)
    }

    @Test("An empty or absent bucket list yields no reading")
    func noBuckets() throws {
        #expect(try decode(#"{"buckets":[]}"#).usage == nil)
        #expect(try decode(#"{}"#).usage == nil)
    }

    @Test("Quota summary maps Gemini five-hour and weekly windows")
    func mapsQuotaSummaryWindows() throws {
        let response = try JSONDecoder().decode(GeminiQuotaSummaryResponse.self, from: Data("""
        {"groups":[
          {"displayName":"Gemini Models","buckets":[
            {"bucketId":"gemini-five-hour","displayName":"5 hour limit","remaining":{"remainingFraction":0.72,"resetTime":"2026-08-08T12:00:00Z"}},
            {"bucketId":"gemini-weekly","displayName":"Weekly limit","remaining":{"remainingFraction":0.31,"resetTime":"2026-08-12T12:00:00Z"}}
          ]},
          {"displayName":"Claude and GPT models","buckets":[
            {"displayName":"Weekly limit","remaining":{"remainingFraction":0.01}}
          ]}
        ]}
        """.utf8))
        let usage = try #require(response.usage)
        #expect(abs(try #require(usage.fiveHourRemaining) - 72) < 0.0001)
        #expect(abs(try #require(usage.weekRemaining) - 31) < 0.0001)
        #expect(usage.fiveHourResetAt != nil)
        #expect(usage.weekResetAt != nil)
    }

    @Test("loadCodeAssist exposes the billing project")
    func loadCodeAssist() throws {
        let response = try JSONDecoder().decode(
            LoadCodeAssistResponse.self,
            from: Data(#"{"cloudaicompanionProject":"my-project","currentTier":{"id":"free-tier"}}"#.utf8)
        )
        #expect(response.cloudaicompanionProject == "my-project")
    }
}

// MARK: - Reset dates

@Suite("Reset date parsing")
struct ResetDateTests {
    private struct Window: Decodable {
        let resetAt: Date?
        init(from decoder: Decoder) throws {
            resetAt = try decoder.container(keyedBy: DynamicKey.self).resetDate()
        }
    }

    private func reset(_ json: String) throws -> Date? {
        try JSONDecoder().decode(Window.self, from: Data(json.utf8)).resetAt
    }

    @Test("Every spelling the three providers use is accepted", arguments: [
        "resets_at", "reset_at", "resetAt", "reset_time", "resetTime"
    ])
    func acceptsEveryKey(key: String) throws {
        let date = try #require(try reset(#"{"\#(key)":"2026-08-08T12:00:00Z"}"#))
        #expect(date.timeIntervalSince1970 == 1_786_190_400)
    }

    @Test("Unix seconds and milliseconds both work")
    func numericTimestamps() throws {
        #expect(try reset(#"{"resets_at":1786190400}"#)?.timeIntervalSince1970 == 1_786_190_400)
        #expect(try reset(#"{"resets_at":1786190400000}"#)?.timeIntervalSince1970 == 1_786_190_400)
    }

    @Test("A relative offset is resolved against now")
    func relativeOffset() throws {
        let date = try #require(try reset(#"{"reset_after_seconds":3600}"#))
        #expect(abs(date.timeIntervalSinceNow - 3600) < 5)
    }

    @Test("An absolute timestamp wins over a relative one")
    func absoluteBeatsRelative() throws {
        // Codex sends both; the absolute value is the accurate one.
        let date = try #require(try reset(#"{"resets_at":1786190400,"reset_after_seconds":10}"#))
        #expect(date.timeIntervalSince1970 == 1_786_190_400)
    }

    @Test("No reset information yields nil rather than a bogus date")
    func missing() throws {
        #expect(try reset(#"{"utilization":0.5}"#) == nil)
    }
}

// MARK: - Page scraping

@Suite("Usage page scraping")
struct SubscriptionTextParserTests {
    @Test("A remaining percentage is not inverted by an unrelated 'used'")
    func doesNotInvertRemaining() {
        // "used" appears somewhere on essentially every usage page. Treating its
        // mere presence as proof the number is consumption flipped the reading.
        let text = "your plan and usage. 5 hour limit: 40% remaining. you have used codex today."
        #expect(SubscriptionTextParser.percentage(near: ["5 hour"], in: text) == 40)
    }

    @Test("A percentage described as consumption is inverted")
    func invertsConsumption() {
        let text = "5 hour limit: 40% used"
        #expect(SubscriptionTextParser.percentage(near: ["5 hour"], in: text) == 60)
    }

    @Test("The earliest label in the document wins, not the first in the list")
    func picksEarliestLabel() {
        // "5h" occurs first; the old code returned whichever label appeared
        // earliest in the *array*, so the later "5 hour" block won instead.
        let text = "5h left: 30%. later on the page: 5 hour window 90%"
        #expect(SubscriptionTextParser.percentage(near: ["5 hour", "5h"], in: text) == 30)
    }

    @Test("A fraction is read as consumed over total")
    func readsFraction() {
        #expect(SubscriptionTextParser.percentage(near: ["weekly"], in: "weekly 25 of 100 messages") == 75)
    }

    @Test("Text with no percentage yields nothing")
    func noMatch() {
        #expect(SubscriptionTextParser.percentages(from: "sign in to continue").fiveHour == nil)
        #expect(SubscriptionTextParser.percentages(from: "").week == nil)
    }
}
