import Foundation

/// Turns a model identifier into the short name the row's badge shows.
///
/// Every CLI names its models differently — `claude-opus-5`, `gpt-5.6-sol`,
/// `gemini-3.6-flash-medium`, and occasionally a display name that is already
/// human — so this is a best effort over the shapes seen in the wild, with the raw
/// identifier as the fallback rather than a guess. The provider's logo is already
/// beside the badge, so the vendor is dropped: a row shows "Opus 5", not
/// "Claude Opus 5".
enum ModelLabel {
    /// `nil` for a session that never reported a model — the badge is then absent
    /// rather than showing a placeholder.
    static func short(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Antigravity reports "auto" when the person let it pick, and that is worth
        // saying: the model is not fixed for the session.
        if trimmed.lowercased() == "auto" { return "Auto" }
        return capped(trimmed.contains(" ") ? displayName(trimmed) : identifier(trimmed))
    }

    /// Already-human names such as `Gemini 3.6 Flash (Medium)`, which is what the
    /// Antigravity CLI writes into its own settings.
    private static func displayName(_ name: String) -> String {
        var text = name
        if let parenthesis = text.firstIndex(of: "(") {
            text = String(text[..<parenthesis])
        }
        text = text.trimmingCharacters(in: .whitespaces)
        for vendor in vendors where text.lowercased().hasPrefix(vendor + " ") {
            text = String(text.dropFirst(vendor.count + 1))
        }
        return text
    }

    private static func identifier(_ id: String) -> String {
        var tokens = id.lowercased().split(separator: "-").map(String.init)
        // Reasoning effort is a setting, not a model, and the release date is the
        // same model by another name. Both cost the badge room it needs.
        while let last = tokens.last, efforts.contains(last) || isReleaseDate(last) {
            tokens.removeLast()
        }
        guard let family = tokens.first, tokens.count > 1 else { return id }

        let rest = Array(tokens.dropFirst())
        let version = rest.filter(isVersion).joined(separator: ".")
        let words = rest.filter { !isVersion($0) }.map(word).joined(separator: " ")

        switch family {
        // `claude-opus-5`, `claude-sonnet-4-6` — the family reads first.
        case "claude":
            return [words, version].filter { !$0.isEmpty }.joined(separator: " ")
        // `gemini-3.6-flash-medium` — the generation reads first.
        case "gemini":
            return [version, words].filter { !$0.isEmpty }.joined(separator: " ")
        // `gpt-5.6-sol`, `gpt-oss-120b` — the vendor prefix is part of the name here,
        // and hyphenated to whatever follows it when there is no version to carry.
        case "gpt":
            guard !version.isEmpty else { return words.isEmpty ? "GPT" : "GPT-\(words)" }
            return [.init("GPT-\(version)"), words].filter { !$0.isEmpty }.joined(separator: " ")
        default:
            return id
        }
    }

    /// `20251001` — a dated snapshot of a model that is otherwise already named.
    private static func isReleaseDate(_ token: String) -> Bool {
        token.count == 8 && token.allSatisfy(\.isNumber)
    }

    private static func isVersion(_ token: String) -> Bool {
        !token.isEmpty && token.allSatisfy { $0.isNumber || $0 == "." }
    }

    private static func word(_ token: String) -> String {
        if let known = names[token] { return known }
        // `120b`, `4o` — a token mixing digits and letters is a size or a variant,
        // and reads as shouted rather than capitalised.
        if token.contains(where: \.isNumber) { return token.uppercased() }
        return token.prefix(1).uppercased() + token.dropFirst()
    }

    /// Capped rather than wrapped: the badge sits between the title and the elapsed
    /// column, and a long name would push both around.
    private static func capped(_ text: String, limit: Int = 16) -> String {
        guard text.count > limit else { return text }
        return text.prefix(limit - 1).trimmingCharacters(in: .whitespaces) + "…"
    }

    private static let efforts: Set<String> = [
        "high", "medium", "low", "thinking", "latest", "preview", "exp"
    ]

    private static let vendors = ["gemini", "claude", "google", "openai", "anthropic"]

    /// Words whose casing a capitalisation rule would get wrong.
    private static let names = [
        "oss": "OSS",
        "gpt": "GPT"
    ]
}
