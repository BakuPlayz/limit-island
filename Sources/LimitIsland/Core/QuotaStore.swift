import Combine
import Foundation
import WebKit

/// One of the two account slots that flank a hardware notch.
enum NotchSide {
    case left
    case right
}

@MainActor
final class QuotaStore: ObservableObject {
    @Published private(set) var meters: [Meter]
    @Published private(set) var usages: [UUID: SubscriptionUsage]
    @Published private(set) var isRefreshing = false
    /// Accounts explicitly placed beside the camera housing. The right side keeps
    /// a useful fallback when empty; the left is intentionally opt-in.
    @Published private(set) var leftPinnedMeterID: UUID?
    @Published private(set) var rightPinnedMeterID: UUID?

    /// One place for the defaults keys. They used to be repeated as literals in
    /// the static loaders, where changing one would silently break persistence.
    private enum DefaultsKey {
        static let meters = "limit-island.meters"
        static let usages = "limit-island.meter-usage"
        static let leftPinnedMeter = "limit-island.left-pinned-meter"
        static let rightPinnedMeter = "limit-island.right-pinned-meter"
    }

    private let reader = SubscriptionUsageReader()
    private var pollTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var refreshGeneration = 0
    private var loginWindows: [UUID: SubscriptionLoginWindowController] = [:]
    private var oauthFlows: [UUID: GeminiOAuthFlow] = [:]
    /// Surfaced in Settings when a sign-in fails, so the attempt does not just
    /// vanish with an empty row left behind.
    @Published var signInError: String?

    init() {
        meters = Self.loadMeters() ?? []
        usages = Self.loadUsages() ?? [:]
        leftPinnedMeterID = UserDefaults.standard.string(forKey: DefaultsKey.leftPinnedMeter).flatMap(UUID.init(uuidString:))
        rightPinnedMeterID = UserDefaults.standard.string(forKey: DefaultsKey.rightPinnedMeter).flatMap(UUID.init(uuidString:))
        clearMissingPins()
    }

    // MARK: - Lifecycle

    func start() {
        refreshAll()
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { return }
                self?.refreshAll()
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        refreshTask?.cancel()
    }

    /// A request suspended with the machine can return stale cookies, dates or
    /// network failures. Start a clean cycle and reset the polling cadence.
    func refreshAfterWake() {
        refreshGeneration &+= 1
        refreshTask?.cancel()
        refreshTask = nil
        isRefreshing = false
        start()
    }

    // MARK: - Reading

    func usage(for meter: Meter) -> SubscriptionUsage {
        usages[meter.id] ?? .empty(meter.provider)
    }

    /// The account used as the unpinned right-side fallback.
    ///
    /// There is room beside the notch for exactly one line, and the account worth
    /// putting there is the one closest to running out — a comfortable account
    /// tells you nothing you need to act on. Every account is still listed in the
    /// panel.
    /// Accounts belonging to a provider that is currently switched on. A meter for a
    /// hidden provider is kept in storage untouched — turning the provider back on
    /// brings the account back rather than asking the user to sign in again.
    var visibleMeters: [Meter] {
        meters.filter(\.provider.isAvailable)
    }

    var headlineMeter: Meter? {
        let visible = visibleMeters
        let ready = visible.filter { usage(for: $0).status == .ready }
        let ranked = ready.isEmpty ? visible : ready
        return ranked.min { left, right in
            (scarcity(of: left) ?? .infinity) < (scarcity(of: right) ?? .infinity)
        }
    }

    var leftPinnedMeter: Meter? {
        meter(id: leftPinnedMeterID)
    }

    /// The closed strip shows only explicitly pinned accounts. This keeps the two
    /// physical sides stable instead of making a fallback appear on one side.
    var rightStripMeter: Meter? {
        meter(id: rightPinnedMeterID)
    }

    /// Lowest remaining percentage across an account's windows, or nil when it has
    /// no reading at all.
    private func scarcity(of meter: Meter) -> Double? {
        let usage = usage(for: meter)
        return [usage.fiveHourRemaining, usage.weekRemaining].compactMap { $0 }.min()
    }

    /// Local logins not already represented by a meter.
    var availableAccounts: [DetectedAccount] {
        let taken = Set(meters.filter { $0.credential == .localCLI }.map(\.provider))
        return AccountDetector.detectedAccounts().filter { !taken.contains($0.provider) }
    }

    func refreshAll() {
        guard !isRefreshing else { return }
        isRefreshing = true
        refreshGeneration &+= 1
        let generation = refreshGeneration
        // Held so `stop()` can cancel it. Previously the task was dropped, and
        // any path that lost it left `isRefreshing` true forever — which the
        // guard above turns into a permanently dead refresh.
        refreshTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.refreshGeneration == generation { self.isRefreshing = false }
            }
            // Serially, a cycle could outrun its own 60-second interval: each read
            // allows 20 s and the scraping fallback sleeps a further 5 s, so six
            // accounts were enough to never finish. Three at a time keeps a cycle
            // bounded without opening six WebKit page loads at once.
            let queued = self.meters
            await withTaskGroup(of: Void.self) { group in
                var running = 0
                for meter in queued {
                    if running == 3 {
                        await group.next()
                        running -= 1
                    }
                    guard !Task.isCancelled else { break }
                    group.addTask { await self.refresh(meter) }
                    running += 1
                }
            }
        }
    }

    func refresh(_ meter: Meter) async {
        let previous = usage(for: meter)
        var current = previous
        current.status = .reading
        usages[meter.id] = current
        let next = await reader.read(meter: meter)

        // A read takes seconds, and the user can delete the meter while it is in
        // flight. Writing the result then would resurrect the row's usage record
        // and persist it for a meter that no longer exists.
        guard meters.contains(where: { $0.id == meter.id }) else {
            usages[meter.id] = nil
            return
        }

        // Provider session endpoints can transiently fail during refreshes, so a
        // blip should not visually disconnect a working account. But a rejected
        // or missing credential is a settled fact rather than a blip: holding the
        // last good percentage over it is how a signed-out account went on
        // showing a stale reading indefinitely.
        if next.status == .unavailable, previous.status == .ready {
            usages[meter.id] = previous
        } else {
            usages[meter.id] = next
        }
        persistUsages()
        await refreshIdentity(for: meter)
    }

    /// Fills in a meter's label from the account itself, so the common case
    /// needs no typing. A user rename always wins.
    private func refreshIdentity(for meter: Meter) async {
        guard meter.detectedLabel == nil else { return }
        guard let identity = await reader.detectIdentity(for: meter), !identity.isEmpty else { return }
        guard let index = meters.firstIndex(where: { $0.id == meter.id }) else { return }
        meters[index].detectedLabel = identity
        persistMeters()
    }

    // MARK: - Editing

    func add(_ account: DetectedAccount) {
        let meter = Meter(
            provider: account.provider,
            detectedLabel: account.label,
            credential: account.credential
        )
        meters.append(meter)
        persistMeters()
        Task { await refresh(meter) }
    }

    /// Adds an account the user signs into from Settings.
    ///
    /// Gemini takes a different route: Google's quota endpoint ignores browser
    /// cookies, so a website data store would never produce a number. It gets a
    /// real OAuth grant instead, which is also why the consent page opens in the
    /// user's browser rather than in the in-app sign-in window.
    func addBrowserAccount(for provider: Provider) {
        signInError = nil

        if provider == .gemini {
            let meter = Meter(provider: provider, credential: .googleOAuth(UUID()))
            meters.append(meter)
            persistMeters()
            startGoogleSignIn(for: meter)
            return
        }

        let meter = Meter(provider: provider, credential: .browserSession(UUID()))
        meters.append(meter)
        persistMeters()
        openLoginWindow(for: meter)
    }

    private func startGoogleSignIn(for meter: Meter) {
        let flow = GeminiOAuthFlow()
        oauthFlows[meter.id] = flow
        Task { [weak self] in
            defer { self?.oauthFlows[meter.id] = nil }
            do {
                let token = try await flow.signIn()
                guard let self, let identifier = meter.credential.oauthIdentifier else { return }
                await GeminiCredentialStore.shared.store(token, for: identifier)
                await self.refresh(meter)
            } catch {
                Log.auth.error("gemini sign-in failed: \(error.localizedDescription, privacy: .public)")
                guard let self else { return }
                // Do not leave a meter that can never read anything.
                self.remove(meter)
                self.signInError = error.localizedDescription
            }
        }
    }

    func remove(_ meter: Meter) {
        meters.removeAll { $0.id == meter.id }
        usages[meter.id] = nil
        loginWindows[meter.id] = nil
        oauthFlows[meter.id]?.cancel()
        oauthFlows[meter.id] = nil
        clearPin(for: meter.id)
        persistMeters()
        persistUsages()
        Task { await reader.clearSession(for: meter) }
    }

    func rename(_ meter: Meter, to name: String) {
        guard let index = meters.firstIndex(where: { $0.id == meter.id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        meters[index].customLabel = trimmed.isEmpty ? nil : trimmed
        persistMeters()
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        meters.move(fromOffsets: source, toOffset: destination)
        persistMeters()
    }

    // MARK: - Notch pins

    func pin(_ meter: Meter, to side: NotchSide) {
        guard meters.contains(where: { $0.id == meter.id }) else { return }
        switch side {
        case .left:
            leftPinnedMeterID = meter.id
            if rightPinnedMeterID == meter.id { rightPinnedMeterID = nil }
        case .right:
            rightPinnedMeterID = meter.id
            if leftPinnedMeterID == meter.id { leftPinnedMeterID = nil }
        }
        persistPins()
    }

    func unpin(_ side: NotchSide) {
        switch side {
        case .left: leftPinnedMeterID = nil
        case .right: rightPinnedMeterID = nil
        }
        persistPins()
    }

    // MARK: - Sign-in

    func openLoginWindow(for meter: Meter) {
        // Gemini has no in-app sign-in: Google refuses OAuth in an embedded web
        // view, so its consent page goes to the user's browser instead.
        if meter.provider == .gemini {
            signInError = nil
            startGoogleSignIn(for: meter)
            return
        }
        if let existing = loginWindows[meter.id] {
            existing.show()
            return
        }
        let controller = SubscriptionLoginWindowController(
            meter: meter,
            webView: reader.makeLoginView(for: meter)
        )
        controller.onClose = { [weak self] in self?.loginWindows[meter.id] = nil }
        loginWindows[meter.id] = controller
        controller.show()
    }

    func signOut(_ meter: Meter) async {
        await reader.clearSession(for: meter)
        usages[meter.id] = .empty(meter.provider)
        if let index = meters.firstIndex(where: { $0.id == meter.id }) {
            meters[index].detectedLabel = nil
        }
        loginWindows[meter.id] = nil
        oauthFlows[meter.id]?.cancel()
        oauthFlows[meter.id] = nil
        persistMeters()
        persistUsages()
    }

    // MARK: - Persistence

    private func persistMeters() {
        do {
            UserDefaults.standard.set(try JSONEncoder().encode(meters), forKey: DefaultsKey.meters)
        } catch {
            Log.usage.error("could not save accounts: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func persistUsages() {
        let records = usages.map { PersistedUsage(meterID: $0.key, usage: $0.value) }
        do {
            UserDefaults.standard.set(try JSONEncoder().encode(records), forKey: DefaultsKey.usages)
        } catch {
            Log.usage.error("could not save readings: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func persistPins() {
        UserDefaults.standard.set(leftPinnedMeterID?.uuidString, forKey: DefaultsKey.leftPinnedMeter)
        UserDefaults.standard.set(rightPinnedMeterID?.uuidString, forKey: DefaultsKey.rightPinnedMeter)
    }

    private func meter(id: UUID?) -> Meter? {
        guard let id else { return nil }
        return visibleMeters.first { $0.id == id }
    }

    private func clearMissingPins() {
        let ids = Set(visibleMeters.map(\.id))
        var changed = false
        if let leftPinnedMeterID, !ids.contains(leftPinnedMeterID) {
            self.leftPinnedMeterID = nil
            changed = true
        }
        if let rightPinnedMeterID, !ids.contains(rightPinnedMeterID) {
            self.rightPinnedMeterID = nil
            changed = true
        }
        if changed { persistPins() }
    }

    private func clearPin(for meterID: UUID) {
        var changed = false
        if leftPinnedMeterID == meterID {
            leftPinnedMeterID = nil
            changed = true
        }
        if rightPinnedMeterID == meterID {
            rightPinnedMeterID = nil
            changed = true
        }
        if changed { persistPins() }
    }

    private static func loadMeters() -> [Meter]? {
        guard let data = UserDefaults.standard.data(forKey: DefaultsKey.meters),
              let values = try? JSONDecoder().decode([Meter].self, from: data) else { return nil }
        return values
    }

    private static func loadUsages() -> [UUID: SubscriptionUsage]? {
        guard let data = UserDefaults.standard.data(forKey: DefaultsKey.usages),
              let records = try? JSONDecoder().decode([PersistedUsage].self, from: data) else { return nil }
        return Dictionary(uniqueKeysWithValues: records.map { ($0.meterID, $0.usage) })
    }

}

private struct PersistedUsage: Codable {
    let meterID: UUID
    let usage: SubscriptionUsage
}
