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

    public init(url: URL = AppPaths.storeFile(), strategy: RotationStrategy = .priority) {
        self.url = url
        self.strategy = strategy
        self.data = AccountStore.loadFrom(url) ?? StoreData()
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

    private func eligibleSorted(now: Date) -> [Account] {
        data.accounts
            .filter { $0.isEligible(now: now) }
            .sorted { a, b in
                if a.priority != b.priority { return a.priority > b.priority }
                let la = a.lastUsedAt ?? .distantPast
                let lb = b.lastUsedAt ?? .distantPast
                if la != lb { return la < lb }
                return a.alias < b.alias
            }
    }

    public func bestEligible(among aliases: [String], now: Date = Date()) -> Account? {
        let allowed = Set(aliases)
        return data.accounts
            .filter { allowed.contains($0.alias) && $0.isEligible(now: now) }
            .sorted { a, b in
                if a.priority != b.priority { return a.priority > b.priority }
                let la = a.lastUsedAt ?? .distantPast
                let lb = b.lastUsedAt ?? .distantPast
                if la != lb { return la < lb }
                return a.alias < b.alias
            }
            .first
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
        guard let i = index(alias) else { return nil }
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
        data.accounts[i].usage = windows
        // Fresh usage reporting headroom supersedes a recorded cooldown: a limit hit before
        // an early reset (or lifted upstream) must not park the account until the stale
        // resets_at. A limit that still holds re-establishes its cooldown on the next 429.
        if !windows.isEmpty, windows.allSatisfy({ $0.usedPercent < 100 }),
           !data.accounts[i].disabledUntil.isEmpty {
            data.accounts[i].disabledUntil = [:]
        }
        persist()
    }

    public func setPriority(_ alias: String, priority: Int) {
        guard let i = index(alias) else { return }
        data.accounts[i].priority = priority
        persist()
    }

    public func remove(_ alias: String) {
        data.accounts.removeAll { $0.alias == alias }
        if data.activeAlias == alias { data.activeAlias = nil }
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
        if let i = data.accounts.firstIndex(where: { !$0.accountID.isEmpty && $0.accountID == account.accountID })
            ?? data.accounts.firstIndex(where: { $0.alias == account.alias }) {
            var merged = account
            merged.priority = data.accounts[i].priority
            merged.alias = data.accounts[i].alias
            merged.disabledUntil = data.accounts[i].disabledUntil
            merged.lastUsedAt = data.accounts[i].lastUsedAt
            merged.managedHomePath = account.managedHomePath ?? data.accounts[i].managedHomePath
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
        persist()
        return account
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
