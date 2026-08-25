import Foundation
import SwiftUI
import Testing
@testable import LimitIsland

@Suite("Notch layout")
struct NotchLayoutTests {
    @Test("Pinned slots use one stable shared width")
    func pinnedSlotIsFixed() {
        #expect(NotchLayout.pinnedSlotWidth == 124)
    }

    @Test("A side with no content takes no width at all")
    func emptyContentTakesNoWidth() {
        // Otherwise an account with no reading would still paint a black stub
        // beside the notch.
        #expect(NotchLayout.sideWidth(contentWidth: 0) == 0)
    }

    @Test("A side always leaves clearance beside the camera housing")
    func sideWidthKeepsItsInset() {
        // This is the margin that stops a readout butting up against the housing.
        // It is added on top of the measured content, never taken out of it.
        for content in [10.0, 50.0, 120.0] {
            let width = NotchLayout.sideWidth(contentWidth: content)
            #expect(width >= content + NotchLayout.notchInset)
        }
    }

    @Test("The panel grows with its content but stops at the ceiling")
    func panelHeightIsBounded() {
        let header = NotchLayout.minimumHeaderHeight
        let small = NotchLayout.panelHeight(sessions: 1, cards: 0, headerHeight: header)
        let larger = NotchLayout.panelHeight(sessions: 4, cards: 0, headerHeight: header)
        #expect(small < larger)
        #expect(NotchLayout.panelHeight(sessions: 200, cards: 1, headerHeight: header, cardHeight: 1_000) == NotchLayout.maximumPanelHeight - header)
    }

    @Test("An empty panel still has room for its empty state")
    func emptyPanelHasHeight() {
        let header = NotchLayout.minimumHeaderHeight
        #expect(NotchLayout.panelHeight(sessions: 0, cards: 0, headerHeight: header) == NotchLayout.rowHeight + 16)
    }

    @Test("Normal content height excludes the separately rendered header")
    func headerIsNotDoubleCounted() {
        let header = NotchLayout.minimumHeaderHeight
        #expect(NotchLayout.panelHeight(sessions: 2, cards: 0, headerHeight: header) == 2 * NotchLayout.rowHeight + 16)
        #expect(header + NotchLayout.panelHeight(sessions: 2, cards: 0, headerHeight: header) ==
                header + 2 * NotchLayout.rowHeight + 16)
    }

    @Test("Interaction height does not depend on hidden session rows")
    func interactionHeightIsIndependent() {
        let header = NotchLayout.minimumHeaderHeight
        #expect(NotchLayout.panelHeight(sessions: 1, cards: 1, headerHeight: header) ==
                NotchLayout.panelHeight(sessions: 100, cards: 1, headerHeight: header))
    }

    @Test("Interaction height follows the measured card")
    func measuredInteractionHeight() {
        let header = NotchLayout.minimumHeaderHeight
        #expect(NotchLayout.panelHeight(sessions: 10, cards: 1, headerHeight: header, cardHeight: 230) == 230)
        #expect(NotchLayout.panelHeight(sessions: 10, cards: 1, headerHeight: header, cardHeight: 310) == 310)
    }
}

@MainActor
@Suite("Notch clearance")
struct NotchClearanceTests {
    /// The bug these guard against: the window was sized from a font measurement of
    /// a sample string while the view rendered something else, so when the content
    /// was wider the strip overflowed and the quota readout slid under the camera
    /// housing.
    @Test("The panel's top band is never shorter than the camera housing")
    func headerClearsTheNotch() {
        let presenter = IslandPresenter()
        // Housings vary by model; the band has to follow the display, not a constant.
        for housing in [24.0, 32.0, 38.0, 44.0] {
            presenter.notchHeight = housing
            #expect(presenter.headerHeight >= housing)
        }
    }

    @Test("A short housing still gets a legible band")
    func headerHasAFloor() {
        let presenter = IslandPresenter()
        presenter.notchHeight = 4
        #expect(presenter.headerHeight == NotchLayout.minimumHeaderHeight)
    }

    @Test("Measuring the real readout agrees with what it renders")
    func measurementTracksTheView() {
        let meter = Meter(provider: .claude, credential: .localCLI)
        let narrow = SubscriptionUsage(
            provider: .claude, fiveHourRemaining: 9, weekRemaining: 4,
            updatedAt: .now, status: .ready
        )
        // A reading with reset dates renders two extra countdowns, so it must
        // measure wider than one without. A fixed sample string could not know that.
        let wide = SubscriptionUsage(
            provider: .claude, fiveHourRemaining: 100, weekRemaining: 100,
            fiveHourResetAt: .now.addingTimeInterval(86_399),
            weekResetAt: .now.addingTimeInterval(86_399),
            updatedAt: .now, status: .ready
        )
        let narrowWidth = NotchLayout.measuredWidth(of: QuotaReadout(meter: meter, usage: narrow))
        let wideWidth = NotchLayout.measuredWidth(of: QuotaReadout(meter: meter, usage: wide))

        #expect(narrowWidth > 0)
        #expect(wideWidth > narrowWidth)
    }

    @Test("The presenter only publishes real changes")
    func guardedAssignment() {
        // `@Observable` notifies on every set, and the controller recomputes these
        // on every session event. Without the guard the notch re-rendered whenever
        // an agent so much as changed activity.
        let presenter = IslandPresenter()
        presenter.set(\.notchWidth, to: 180)
        #expect(presenter.notchWidth == 180)
        presenter.set(\.notchWidth, to: 180)
        #expect(presenter.notchWidth == 180)
        presenter.set(\.notchWidth, to: 200)
        #expect(presenter.notchWidth == 200)
    }
}

@Suite("Reset countdown")
struct ResetCountdownTests {
    @Test("No reset date reads as a dash rather than a zero")
    func missingDate() {
        #expect(ResetCountdown.compact(nil) == "—")
        #expect(ResetCountdown.absolute(nil) == nil)
        #expect(ResetCountdown.settings(nil) == nil)
    }

    @Test("Settings reset time uses the full local date and time")
    func settingsDate() throws {
        let reset = Date(timeIntervalSince1970: 1_786_190_400)
        let formatted = try #require(ResetCountdown.settings(reset))
        #expect(formatted == reset.formatted(date: .abbreviated, time: .shortened))
    }

    /// Hours carry their minutes because "4h" and "4h59m" are the difference
    /// between waiting and going to lunch.
    @Test("The countdown coarsens as the reset moves further out", arguments: ResetCountdownTests.unitCases)
    func units(_ testCase: (offset: Double, expected: String)) {
        let rendered = ResetCountdown.compact(.now.addingTimeInterval(testCase.offset + 1))
        #expect(rendered == testCase.expected)
    }

    static let unitCases: [(offset: Double, expected: String)] = [
        (30, "<1m"),
        (60 * 5, "5m"),
        (3_600 * 3, "3h"),
        (3_600 * 4 + 60, "4h1m"),
        (3_600 * 6 + 60, "6h1m"),
        (86_400 * 2, "2d"),
        (86_400 * 2 + 3_600 * 5, "2d5h")
    ]

    @Test("A reset already in the past does not render as negative")
    func pastDate() {
        #expect(ResetCountdown.compact(.now.addingTimeInterval(-5_000)) == "<1m")
    }

    @Test("The countdown stays short enough for one strip line")
    func staysShort() {
        // Six is the true ceiling — `23h59m` — and `QuotaReadout.widestRendering`
        // reserves space for exactly that. A longer form would clip the strip.
        let offsets: [TimeInterval] = [0, 59, 61, 3_599, 3_601, 86_399, 86_401, 86_400 * 400]
        for offset in offsets {
            let rendered = ResetCountdown.compact(.now.addingTimeInterval(offset))
            #expect(rendered.count <= 6, "\(offset)s rendered as \(rendered)")
        }
    }
}

@Suite("Account model")
struct MeterTests {
    @Test("A rename outranks the detected identity")
    func labelPrecedence() {
        var meter = Meter(provider: .gemini, detectedLabel: "me@example.com", credential: .localCLI)
        #expect(meter.displayLabel == "me@example.com")
        meter.customLabel = "Work"
        #expect(meter.displayLabel == "Work")
        meter.customLabel = ""
        #expect(meter.displayLabel == "me@example.com")
        meter.detectedLabel = nil
        #expect(meter.displayLabel == "Gemini")
    }

    @Test("Accounts saved by the ring-era build still load")
    func decodesRetiredSideField() throws {
        // `side` was persisted by every earlier build. Dropping the property must
        // not orphan someone's configured accounts.
        let saved = """
        {"id":"5522CC7C-722E-4272-B6F9-E4F1FF567001","provider":"claude","side":"left",\
        "credential":{"localCLI":{}}}
        """
        let meter = try JSONDecoder().decode(Meter.self, from: Data(saved.utf8))
        #expect(meter.provider == .claude)
        #expect(meter.credential == .localCLI)
    }

    @Test("Credential identifiers do not leak across kinds")
    func credentialIdentifiers() {
        let id = UUID()
        #expect(CredentialSource.browserSession(id).sessionIdentifier == id)
        #expect(CredentialSource.browserSession(id).oauthIdentifier == nil)
        #expect(CredentialSource.googleOAuth(id).oauthIdentifier == id)
        #expect(CredentialSource.googleOAuth(id).sessionIdentifier == nil)
        #expect(CredentialSource.localCLI.sessionIdentifier == nil)
        #expect(CredentialSource.localCLI.oauthIdentifier == nil)
    }

    @Test("Adding the OAuth case keeps already-saved accounts readable")
    func credentialsRoundTripAndStayCompatible() throws {
        // Accounts persisted before `googleOAuth` existed must still decode.
        let saved = #"{"browserSession":{"_0":"5522CC7C-722E-4272-B6F9-E4F1FF567001"}}"#
        let decoded = try JSONDecoder().decode(CredentialSource.self, from: Data(saved.utf8))
        #expect(decoded.sessionIdentifier?.uuidString == "5522CC7C-722E-4272-B6F9-E4F1FF567001")

        for source in [CredentialSource.localCLI, .browserSession(UUID()), .googleOAuth(UUID())] {
            let data = try JSONEncoder().encode(source)
            #expect(try JSONDecoder().decode(CredentialSource.self, from: data) == source)
        }
    }

    @MainActor
    @Test("Pinned notch accounts stay distinct and clear when removed")
    func notchPins() throws {
        let defaults = UserDefaults.standard
        let keys = [
            "limit-island.meters",
            "limit-island.meter-usage",
            "limit-island.left-pinned-meter",
            "limit-island.right-pinned-meter"
        ]
        let saved = keys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            for (key, value) in saved {
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }

        let codex = Meter(provider: .openAI, credential: .browserSession(UUID()))
        let claude = Meter(provider: .claude, credential: .browserSession(UUID()))
        defaults.set(try JSONEncoder().encode([codex, claude]), forKey: "limit-island.meters")
        defaults.removeObject(forKey: "limit-island.meter-usage")
        defaults.removeObject(forKey: "limit-island.left-pinned-meter")
        defaults.removeObject(forKey: "limit-island.right-pinned-meter")

        let store = QuotaStore()
        store.pin(codex, to: .left)
        store.pin(claude, to: .right)
        #expect(store.leftPinnedMeterID == codex.id)
        #expect(store.rightPinnedMeterID == claude.id)

        // An account owns at most one side, so moving it right frees the left.
        store.pin(codex, to: .right)
        #expect(store.leftPinnedMeterID == nil)
        #expect(store.rightPinnedMeterID == codex.id)

        store.remove(codex)
        #expect(store.rightPinnedMeterID == nil)
        #expect(store.rightStripMeter == nil)
    }

    @Test("Every provider has a bundled logo")
    func logosAreBundled() {
        // The Gemini PNG went missing from the source tree once and survived only
        // as stale build output, so the app silently drew an SF Symbol instead.
        for provider in Provider.allCases {
            #expect(
                Bundle.module.url(forResource: provider.assetName, withExtension: "png") != nil,
                "missing \(provider.assetName).png"
            )
        }
    }
}

@Suite("Codex id token claims")
struct AccountDetectorTests {
    @Test("Claims are read out of the base64url payload")
    func decodesClaims() throws {
        let payload = Data(#"{"email":"me@example.com"}"#.utf8).base64URLEncoded
        let claims = try #require(AccountDetector.idTokenClaims(from: ["id_token": "header.\(payload).signature"]))
        #expect(claims["email"] as? String == "me@example.com")
    }

    @Test("A malformed or absent token yields nothing rather than crashing")
    func rejectsJunk() {
        #expect(AccountDetector.idTokenClaims(from: [:]) == nil)
        #expect(AccountDetector.idTokenClaims(from: ["id_token": "nodots"]) == nil)
        #expect(AccountDetector.idTokenClaims(from: ["id_token": "a.!!!!.c"]) == nil)
    }
}

@Suite("Auto-continue card layout")
@MainActor
struct AutoContinueCardLayoutTests {
    private func session(id: String, project: String) -> AgentSession {
        AgentSession(
            id: id, provider: .claude, project: project, lastPrompt: nil,
            activity: .done,
            terminal: TerminalRef(
                program: "Apple_Terminal", tty: "/dev/ttys00\(id)",
                workingDirectory: "/tmp/\(project)", agentPID: 1_000, pids: [1_000]
            ),
            startedAt: .now, lastEventAt: .now
        )
    }

    private func height(sessions: [AgentSession], scheduled: ScheduledContinue? = nil) -> CGFloat {
        let card = AutoContinueCard(
            sessions: sessions, resetAt: .now.addingTimeInterval(3_600),
            scheduled: scheduled, outcome: nil,
            onSchedule: { _, _ in }, onDismiss: {}, onCancel: {},
            onAcknowledge: {}, onComposing: { _ in }
        )
        let ruler = NSHostingView(rootView: card.frame(width: NotchLayout.panelWidth))
        ruler.frame = NSRect(x: 0, y: 0, width: NotchLayout.panelWidth, height: 0)
        return ceil(ruler.fittingSize.height)
    }

    private func budget(sessionCount: Int, isArmed: Bool) -> CGFloat {
        CGFloat(AutoContinueCard.rowBudget(sessionCount: sessionCount, isArmed: isArmed))
            * NotchLayout.rowHeight
    }

    /// `IslandWindowController` sizes the window from `AutoContinueCard.rowBudget`,
    /// and the card has to fit inside what it asked for. A clipped cost note is a
    /// hedge nobody reads, which is the one thing this card must not do.
    @Test("The offer fits the rows the window reserves for it")
    func offerFitsItsBudget() {
        for count in 1...4 {
            let sessions = (1...count).map { session(id: "\($0)", project: "project-\($0)") }
            #expect(height(sessions: sessions) <= budget(sessionCount: count, isArmed: false))
        }
    }

    @Test("An armed schedule collapses into the rows it is budgeted")
    func armedRowFitsItsBudget() {
        let sessions = [session(id: "1", project: "vibe-usage")]
        let plan = ScheduledContinue(
            sessionID: "1", project: "vibe-usage",
            terminal: sessions[0].terminal!,
            message: AutoContinueStore.defaultMessage,
            fireAt: .now.addingTimeInterval(3_660), resetAt: .now.addingTimeInterval(3_600)
        )
        #expect(height(sessions: sessions, scheduled: plan) <= budget(sessionCount: 1, isArmed: true))
    }
}
