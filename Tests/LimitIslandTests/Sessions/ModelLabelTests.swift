import Testing
@testable import LimitIsland

/// The badge is roughly a dozen characters wide, and what a person is looking for
/// in it is "which model", not "which reasoning effort".
@Suite("Model labels")
struct ModelLabelTests {
    @Test("Claude identifiers read as the family and its version")
    func claude() {
        #expect(ModelLabel.short("claude-opus-5") == "Opus 5")
        #expect(ModelLabel.short("claude-sonnet-4-6") == "Sonnet 4.6")
        // The dated snapshot is the same model as the name in front of it.
        #expect(ModelLabel.short("claude-haiku-4-5-20251001") == "Haiku 4.5")
        #expect(ModelLabel.short("claude-opus-4-6-thinking") == "Opus 4.6")
    }

    @Test("Gemini identifiers lead with the generation")
    func gemini() {
        #expect(ModelLabel.short("gemini-3.6-flash-medium") == "3.6 Flash")
        #expect(ModelLabel.short("gemini-3.1-pro-high") == "3.1 Pro")
    }

    @Test("GPT keeps its prefix, which is part of the name")
    func openAI() {
        #expect(ModelLabel.short("gpt-5.6-sol") == "GPT-5.6 Sol")
        #expect(ModelLabel.short("gpt-oss-120b-medium") == "GPT-OSS 120B")
    }

    @Test("A name that is already human loses only the vendor and the effort")
    func displayNames() {
        #expect(ModelLabel.short("Gemini 3.6 Flash (Medium)") == "3.6 Flash")
        #expect(ModelLabel.short("Claude Opus 4.6 (Thinking)") == "Opus 4.6")
        #expect(ModelLabel.short("GPT-OSS 120B (Medium)") == "GPT-OSS 120B")
    }

    @Test("Letting the CLI choose is worth saying")
    func auto() {
        #expect(ModelLabel.short("auto") == "Auto")
    }

    @Test("An identifier we have never seen is shown as it is")
    func unknown() {
        #expect(ModelLabel.short("codex-mini") == "codex-mini")
        #expect(ModelLabel.short("llama3") == "llama3")
    }

    @Test("Nothing to say means no badge at all")
    func absent() {
        #expect(ModelLabel.short(nil) == nil)
        #expect(ModelLabel.short("") == nil)
        #expect(ModelLabel.short("   ") == nil)
    }

    @Test("A name too long for the badge is cut rather than allowed to push the row")
    func capped() {
        let label = ModelLabel.short("some-extremely-long-model-identifier")
        #expect(label?.count ?? 0 <= 16)
        #expect(label?.hasSuffix("…") == true)
    }
}
