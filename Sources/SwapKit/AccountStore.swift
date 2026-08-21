import Foundation

struct StoreData: Codable {
    var schemaVersion: Int = 1
    var activeAlias: String?
    var accounts: [Account] = []
}

public struct RotationResult: Sendable {
    public let next: Account?
    public let rotated: Bool
}

public actor AccountStore {
    private let url: URL
    private var data: StoreData
    public private(set) var strategy: RotationStrategy
    /// Aliases currently assessed as draining from other users' activity (smart switch).
    private var drainingAliases: Set<String> = []
    private static let historyCap = 64

    public init(url: URL = AppPaths.storeFile(), strategy: RotationStrategy = .priority) {
        self.url = url
        self.strategy = strategy
        var loaded = AccountStore.loadFrom(url) ?? StoreData()
        loaded.accounts = loaded.accounts.map { account in
            var normalized = account
            normalized.priority = max(0, account.priority)
            return normalized
        }
        Self.renumberRanks(&loaded)
        self.data = loaded
    }

    public func setStrategy(_ s: RotationStrategy) { strategy = s }

    // MARK: - Persistence

    private static func loadFrom(_ url: URL) -> StoreData? {
        guard let raw = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder.codex.decode(StoreData.self, from: raw)
    }

    private func persist() {
        let encoder = JSONEncoder.codex
        guard let raw = try? encoder.encode(data) else { return }
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let tmp = url.appendingPathExtension("tmp")
        guard FileManager.default.createFile(atPath: tmp.path, contents: raw, attributes: [.posixPermissions: 0o600]) else { return }
        _ = try? FileManager.default.replaceItemAt(url, withItemAt: tmp)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    // MARK: - Reads

    public func all() -> [Account] { data.accounts }
    public func activeAlias() -> String? { data.activeAlias }
    public func account(_ alias: String) -> Account? { data.accounts.first { $0.alias == alias } }

    private func index(_ alias: String) -> Int? { data.accounts.firstIndex { $0.alias == alias } }

    /// Shared ordering for picking the next account: priority strategy ranks by priority
    /// first, round-robin spreads by least-recently-used; both tiebreak LRU then alias.
    static func selectionOrder(_ a: Account, _ b: Account, strategy: RotationStrategy) -> Bool {
        if strategy == .priority, a.priority != b.priority { return a.priority > b.priority }
        let la = a.lastUsedAt ?? .distantPast
        let lb = b.lastUsedAt ?? .distantPast
        if la != lb { return la < lb }
        return a.alias < b.alias
    }

    private func eligibleSorted(now: Date) -> [Account] {
        strategySorted(data.accounts.filter { $0.isEligible(now: now) }, strategy: .priority)
    }

    /// Applies the configured strategy order, then floats smart-switch draining accounts ahead.
    private func strategySorted(_ accounts: [Account], strategy: RotationStrategy) -> [Account] {
        let base = accounts.sorted { Self.selectionOrder($0, $1, strategy: strategy) }
        guard !drainingAliases.isEmpty else { return base }
        let drainState = Dictionary(uniqueKeysWithValues: base.map { ($0.alias, drainingAliases.contains($0.alias)) })
        return SmartSwitchPolicy.sortWithDrainingFirst(base, drainState: drainState)
    }

    /// Best allowed account under the configured rotation strategy, preferring accounts
    /// still under the pre-emptive usage thresholds; when every allowed account is over
    /// threshold, falls back to the best one anyway — same as normal traffic, which keeps
    /// serving on an over-threshold account when nothing else is eligible.
    public func bestEligible(
        among aliases: [String],
        primaryThreshold: Int = Int.max,
        secondaryThreshold: Int = Int.max,
        now: Date = Date()
    ) -> Account? {
        let allowed = Set(aliases)
        let ordered = strategySorted(
            data.accounts.filter { allowed.contains($0.alias) && $0.isEligible(now: now) },
            strategy: strategy
        )
        return ordered.first {
            $0.isWithinRotationThresholds(primaryPercent: primaryThreshold, secondaryPercent: secondaryThreshold)
        } ?? ordered.first
    }

    private func lruEligible(now: Date, excluding: String? = nil) -> Account? {
        data.accounts
            .filter { $0.isEligible(now: now) && $0.alias != excluding }
            .sorted { ($0.lastUsedAt ?? .distantPast) < ($1.lastUsedAt ?? .distantPast) }
            .first
    }

    // MARK: - Selection

    /// The account the proxy should use right now, applying the configured strategy and stickiness.
    public func current(now: Date = Date()) -> Account? {
        switch strategy {
        case .priority:
            let ranked = eligibleSorted(now: now)
            guard let best = ranked.first else { return nil }
            if let active = account(data.activeAlias ?? ""), active.isEligible(now: now), active.priority == best.priority {
                return active
            }
            activate(best.alias, now: now)
            return account(best.alias)
        case .roundRobin:
            if let active = account(data.activeAlias ?? ""), active.isEligible(now: now) {
                return active
            }
            guard let next = lruEligible(now: now) else { return nil }
            activate(next.alias, now: now)
            return account(next.alias)
        }
    }

    private func activate(_ alias: String, now: Date) {
        data.activeAlias = alias
        if let i = index(alias) { data.accounts[i].lastUsedAt = now }
        persist()
    }

    public func touchLastUsed(_ alias: String, now: Date = Date()) {
        guard let i = index(alias) else { return }
        data.accounts[i].lastUsedAt = now
        persist()
    }

    /// Round-robin load balancing: at a new turn, move to the next least-recently-used eligible
    /// account so usage spreads evenly across all of them. Stays put if nothing else is eligible.
    @discardableResult
    public func advanceRoundRobin(now: Date = Date()) -> Account? {
        if let next = lruEligible(now: now, excluding: data.activeAlias) {
            activate(next.alias, now: now)
            return account(next.alias)
        }
        if let active = data.activeAlias, let acc = account(active), acc.isEligible(now: now) { return acc }
        return current(now: now)
    }

    /// Disable `alias` for `limit` until `resetAt`, then pick the next eligible account.
    public func rotateFrom(_ alias: String, limit: String, resetAt: Date?, now: Date = Date(), fallbackCooldown: TimeInterval) -> RotationResult {
        if let i = index(alias) {
            let until = resetAt ?? now.addingTimeInterval(fallbackCooldown)
            data.accounts[i].disabledUntil[limit] = until
        }
        let next: Account?
        switch strategy {
        case .priority:
            next = eligibleSorted(now: now).first { $0.alias != alias }
        case .roundRobin:
            next = lruEligible(now: now, excluding: alias)
        }
        guard let picked = next else { persist(); return RotationResult(next: nil, rotated: false) }
        activate(picked.alias, now: now)
        return RotationResult(next: account(picked.alias), rotated: true)
    }

    public func markLimited(_ alias: String, limit: String, resetAt: Date?, now: Date = Date(), fallbackCooldown: TimeInterval) {
        guard let i = index(alias) else { return }
        data.accounts[i].disabledUntil[limit] = resetAt ?? now.addingTimeInterval(fallbackCooldown)
        persist()
    }

    public func markNeedsLoginOnly(_ alias: String) {
        guard let i = index(alias) else { return }
        data.accounts[i].needsLogin = true
        persist()
    }

    public func markNeedsLogin(_ alias: String, now: Date = Date()) -> RotationResult {
        if let i = index(alias) { data.accounts[i].needsLogin = true }
        let next: Account?
        switch strategy {
        case .priority: next = eligibleSorted(now: now).first { $0.alias != alias }
        case .roundRobin: next = lruEligible(now: now, excluding: alias)
        }
        guard let picked = next else { persist(); return RotationResult(next: nil, rotated: false) }
        activate(picked.alias, now: now)
        return RotationResult(next: account(picked.alias), rotated: true)
    }

    /// Manual switch: clears the target's cooldowns and needs-login, then activates it.
    @discardableResult
    public func setActive(_ alias: String, now: Date = Date()) -> Account? {
        guard let i = index(alias), data.accounts[i].routingEnabled else { return nil }
        data.accounts[i].disabledUntil = [:]
        data.accounts[i].needsLogin = false
        data.accounts[i].lastUsedAt = now
        data.activeAlias = alias
        persist()
        return data.accounts[i]
    }

    // MARK: - Mutations

    /// For CodexBar-managed accounts, adopt CodexBar's token if it's fresher than ours (CodexBar owns refresh).
    public func hydrateFromManagedHome(_ alias: String) -> Account? {
        guard let i = index(alias), let home = data.accounts[i].managedHomePath,
              let tokens = CodexBarBridge.readTokens(home: home) else { return account(alias) }
        let ours = JWT.expiry(data.accounts[i].accessToken) ?? .distantPast
        let theirs = JWT.expiry(tokens.accessToken) ?? .distantPast
        if theirs > ours {
            data.accounts[i].idToken = tokens.idToken
            data.accounts[i].accessToken = tokens.accessToken
            data.accounts[i].refreshToken = tokens.refreshToken
            if !tokens.accountId.isEmpty { data.accounts[i].accountID = tokens.accountId }
            data.accounts[i].needsLogin = false
            persist()
        }
        return data.accounts[i]
    }

    public func managedHome(_ alias: String) -> String? { account(alias)?.managedHomePath }

    public func updateTokens(_ alias: String, tokens: CodexTokens, clearNeedsLogin: Bool = true) {
        guard let i = index(alias) else { return }
        data.accounts[i].idToken = tokens.idToken
        data.accounts[i].accessToken = tokens.accessToken
        data.accounts[i].refreshToken = tokens.refreshToken
        if !tokens.accountId.isEmpty { data.accounts[i].accountID = tokens.accountId }
        if clearNeedsLogin { data.accounts[i].needsLogin = false }
        persist()
    }

    public func updateUsage(_ alias: String, windows: [UsageWindow]) {
        guard let i = index(alias) else { return }
        // wham/usage always reports at least one window for an entitled account; a transient
        // empty response must not wipe a real reading off the display.
        if windows.isEmpty, !data.accounts[i].usage.isEmpty { return }
        data.accounts[i].usage = windows
        appendHistorySamples(at: i, windows: windows)
        // Fresh usage reporting headroom supersedes a recorded cooldown: a limit hit before
        // an early reset (or lifted upstream) must not park the account until the stale
        // resets_at. A limit that still holds re-establishes its cooldown on the next 429.
        if !windows.isEmpty, windows.allSatisfy({ $0.usedPercent < 100 }),
           !data.accounts[i].disabledUntil.isEmpty {
            data.accounts[i].disabledUntil = [:]
        }
        persist()
    }

    /// Appends fresh window readings to the burn-rate history ring (newest last).
    private func appendHistorySamples(at i: Int, windows: [UsageWindow]) {
        let samples = UsageAnalytics.samples(from: windows)
        var history = data.accounts[i].usageHistory ?? []
        history.append(contentsOf: samples)
        if history.count > Self.historyCap {
            history.removeFirst(history.count - Self.historyCap)
        }
        data.accounts[i].usageHistory = history
    }

    /// Folds one completed proxied response into the account's lifetime token totals.
    public func updateUsageStats(
        _ alias: String,
        model: String,
        inputTokens: Int,
        cachedInputTokens: Int,
        outputTokens: Int
    ) {
        guard let i = index(alias) else { return }
        var stats = data.accounts[i].usageStats ?? UsageStats()
        stats.accumulate(
            model: model,
            inputTokens: inputTokens,
            cachedInputTokens: cachedInputTokens,
            outputTokens: outputTokens
        )
        data.accounts[i].usageStats = stats
        persist()
    }

    /// Stamps when CodexSwap itself last routed traffic on this account (drain attribution).
    public func markServed(_ alias: String, date: Date = Date()) {
        guard let i = index(alias) else { return }
        data.accounts[i].lastServedByUs = date
        persist()
    }

    public func setDrainingAliases(_ aliases: Set<String>) {
        drainingAliases = aliases
    }

    public func currentDrainingAliases() -> Set<String> { drainingAliases }

    /// Applies a complete ranking (top first). Ignores orders that are not a permutation
    /// of the current roster; surviving ranks are renumbered densely.
    public func applyRanking(_ orderedAliases: [String]) {
        guard orderedAliases.count == data.accounts.count,
              Set(orderedAliases) == Set(data.accounts.map(\.alias)) else { return }
        let count = orderedAliases.count
        for (position, alias) in orderedAliases.enumerated() {
            if let i = index(alias) {
                data.accounts[i].priority = count - position
            }
        }
        persist()
    }

    /// Moves an account within the priority-sorted ranking and renumbers every rank densely
    /// so the change is always visible. `toIndex` is a position in the ranking where 0 is top.
    public func reorderAccount(_ alias: String, toIndex target: Int) {
        let ranked = data.accounts.sorted { Self.selectionOrder($0, $1, strategy: .priority) }
        guard ranked.count > 1, let from = ranked.firstIndex(where: { $0.alias == alias }) else { return }
        let to = min(max(target, 0), ranked.count - 1)
        guard from != to else { return }
        var reordered = ranked
        let moved = reordered.remove(at: from)
        reordered.insert(moved, at: to)
        // Write back dense ranks by alias so data.accounts ordering itself is untouched.
        let count = reordered.count
        for (position, entry) in reordered.enumerated() {
            if let i = index(entry.alias) {
                data.accounts[i].priority = count - position
            }
        }
        persist()
    }

    public func setPriority(_ alias: String, priority: Int) {
        guard let i = index(alias) else { return }
        // Legacy numeric setter: keep the value in a sane range, then renumber so the
        // ranking stays dense and every rank change stays visible.
        data.accounts[i].priority = max(0, priority)
        renumberRanks()
        persist()
    }

    /// Rewrites priorities to dense ordinals (N…1) preserving relative order so no two
    /// accounts can tie; ties would make rank reordering a silent no-op.
    nonisolated private static func renumberRanks(_ data: inout StoreData) {
        let ranked = data.accounts.sorted { selectionOrder($0, $1, strategy: .priority) }
        let count = ranked.count
        guard count > 0 else { return }
        var newPriorities: [String: Int] = [:]
        for (position, entry) in ranked.enumerated() {
            newPriorities[entry.alias] = count - position
        }
        for i in data.accounts.indices {
            data.accounts[i].priority = newPriorities[data.accounts[i].alias] ?? data.accounts[i].priority
        }
    }

    private func renumberRanks() {
        Self.renumberRanks(&data)
    }

    public func remove(_ alias: String) {
        data.accounts.removeAll { $0.alias == alias }
        if data.activeAlias == alias { data.activeAlias = nil }
        renumberRanks()
        persist()
    }

    /// Drop CodexBar-managed accounts whose accountID is no longer in CodexBar's roster.
    /// Non-managed accounts (e.g. imported from live auth.json) are left untouched.
    @discardableResult
    public func reconcileManaged(present: Set<String>) -> [String] {
        let removed = data.accounts
            .filter { $0.managedHomePath != nil && !present.contains($0.accountID) }
            .map { $0.alias }
        guard !removed.isEmpty else { return [] }
        data.accounts.removeAll { removed.contains($0.alias) }
        if let active = data.activeAlias, removed.contains(active) { data.activeAlias = nil }
        persist()
        return removed
    }

    /// Insert or update an account keyed by accountID (falling back to alias). Preserves priority on update.
    @discardableResult
    public func upsert(_ account: Account) -> Account {
        var account = account
        account.priority = AccountPriority.normalize(account.priority)
        if let i = data.accounts.firstIndex(where: { !$0.accountID.isEmpty && $0.accountID == account.accountID })
            ?? data.accounts.firstIndex(where: { $0.alias == account.alias }) {
            var merged = account
            merged.priority = data.accounts[i].priority
            merged.alias = data.accounts[i].alias
            merged.disabledUntil = data.accounts[i].disabledUntil
            merged.routingEnabled = data.accounts[i].routingEnabled
            merged.lastUsedAt = data.accounts[i].lastUsedAt
            merged.managedHomePath = account.managedHomePath ?? data.accounts[i].managedHomePath
            // needsLogin is runtime overlay state, not import data: the periodic CodexBar
            // sync upserts every account, and imports always carry false, so copying the
            // incoming value here silently re-arms a logged-out account every poll cycle.
            merged.needsLogin = data.accounts[i].needsLogin
            // Imported records never carry usage; the periodic CodexBar sync upserts every
            // account, so dropping the stored windows here blanks the display (and the
            // banked-window gate's input) for up to a poll interval each minute.
            if merged.usage.isEmpty { merged.usage = data.accounts[i].usage }
            // Same preservation for locally observed telemetry: imports never carry it.
            if merged.usageStats == nil { merged.usageStats = data.accounts[i].usageStats }
            if (merged.usageHistory ?? []).isEmpty { merged.usageHistory = data.accounts[i].usageHistory }
            if merged.lastServedByUs == nil { merged.lastServedByUs = data.accounts[i].lastServedByUs }
            // Keep whichever token bundle expires later so a stale on-disk copy never
            // clobbers a fresher one, independent of import order.
            let existingExp = JWT.expiry(data.accounts[i].accessToken) ?? .distantPast
            let incomingExp = JWT.expiry(account.accessToken) ?? .distantPast
            if existingExp > incomingExp {
                merged.accessToken = data.accounts[i].accessToken
                merged.refreshToken = data.accounts[i].refreshToken
                merged.idToken = data.accounts[i].idToken
            }
            data.accounts[i] = merged
            persist()
            return merged
        }
        data.accounts.append(account)
        // Newcomers enter at the BOTTOM of the ranking: their raw priority comes from an
        // incompatible scale (legacy 0–10, CodexBar rosters), so comparing it against the
        // dense ranks would scramble ordering. Rank changes belong to the ranking editor.
        let minimumRank = data.accounts.map(\.priority).min() ?? 2
        if let i = index(account.alias) {
            data.accounts[i].priority = minimumRank - 1
        }
        renumberRanks()
        persist()
        guard let stored = index(account.alias) else { return account }
        return data.accounts[stored]
    }

    public func expireCooldowns(now: Date = Date()) -> [Account] {
        var reset: [Account] = []
        for i in data.accounts.indices {
            let before = data.accounts[i].disabledUntil.count
            data.accounts[i].disabledUntil = data.accounts[i].disabledUntil.filter { $0.value > now }
            if data.accounts[i].disabledUntil.count != before { reset.append(data.accounts[i]) }
        }
        if !reset.isEmpty { persist() }
        return reset
    }

    public func setRoutingEnabled(_ alias: String, enabled: Bool) {
        guard let i = index(alias) else { return }
        data.accounts[i].routingEnabled = enabled
        if !enabled, data.activeAlias == alias { data.activeAlias = nil }
        persist()
    }
}

extension JSONDecoder {
    static var codex: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
extension JSONEncoder {
    static var codex: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return e
    }
}
