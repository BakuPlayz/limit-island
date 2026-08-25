import Foundation
import SwiftUI

enum Provider: String, CaseIterable, Codable, Identifiable, Sendable {
    case openAI
    case claude
    case gemini

    var id: String { rawValue }

    /// Whether this provider is offered in the app at all.
    ///
    /// Gemini was switched off for as long as it had no way to report sessions.
    /// Antigravity's CLI (`agy`) has lifecycle hooks, so it now does: activity,
    /// the model in use, and blocking permission questions all arrive the same way
    /// Claude Code's do. See `HookInstaller.installGemini`.
    var isAvailable: Bool { true }

    /// The providers to show. Everything user-facing enumerates this rather than
    /// `allCases`, so hiding one is a single change rather than a hunt.
    static var available: [Provider] { allCases.filter(\.isAvailable) }

    var title: String {
        switch self {
        case .openAI: "Codex"
        case .claude: "Claude"
        case .gemini: "Gemini"
        }
    }

    var assetName: String {
        switch self {
        case .openAI: "codex"
        case .claude: "claude"
        case .gemini: "gemini"
        }
    }

    /// Drawn only if a bundled PNG is missing, which would mean a broken build.
    var fallbackSymbol: String { "questionmark.circle" }

    var color: Color {
        switch self {
        case .openAI: Color(red: 0.35, green: 0.94, blue: 0.74)
        case .claude: Color(red: 0.96, green: 0.58, blue: 0.34)
        case .gemini: Color(red: 0.36, green: 0.62, blue: 0.98)
        }
    }

    /// Where "Open usage page" goes, and what the scraping fallback loads.
    var usageURL: URL {
        switch self {
        case .openAI: Self.codexUsage
        case .claude: Self.claudeUsage
        case .gemini: Self.geminiHome
        }
    }

    /// Where an OAuth popup lands once sign-in succeeds — the cue to dismiss it.
    var signInReturnHost: String {
        switch self {
        case .openAI: "chatgpt.com"
        case .claude: "claude.ai"
        case .gemini: "google.com"
        }
    }

    private static let codexUsage = URL(string: "https://chatgpt.com/codex/settings/usage")!
    private static let claudeUsage = URL(string: "https://claude.ai/settings/usage")!
    private static let geminiHome = URL(string: "https://gemini.google.com/app")!
}

// Deliberately not `Identifiable`: a usage is keyed by meter, and two meters can
// share a provider, so a provider-derived id would collide.
struct SubscriptionUsage: Codable, Sendable {
    let provider: Provider
    var fiveHourRemaining: Double?
    var weekRemaining: Double?
    var fiveHourResetAt: Date? = nil
    var weekResetAt: Date? = nil
    var updatedAt: Date?
    var status: Status

    enum Status: String, Codable, Sendable {
        case waitingForSignIn
        case reading
        case ready
        case unavailable
    }

    func remaining(in window: QuotaWindow) -> Double? {
        switch window {
        case .fiveHour: fiveHourRemaining
        case .week: weekRemaining
        }
    }

    func resetAt(in window: QuotaWindow) -> Date? {
        switch window {
        case .fiveHour: fiveHourResetAt
        case .week: weekResetAt
        }
    }

    static func empty(_ provider: Provider) -> SubscriptionUsage {
        SubscriptionUsage(provider: provider, fiveHourRemaining: nil, weekRemaining: nil, updatedAt: nil, status: .waitingForSignIn)
    }
}
