import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

struct StoreData: Codable {
    var schemaVersion: Int = 2
    var activeAlias: String?
    var accounts: [Account] = []

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, activeAlias, accounts
    }

    init(schemaVersion: Int = 2, activeAlias: String? = nil, accounts: [Account] = []) {
        self.schemaVersion = schemaVersion
        self.activeAlias = activeAlias
        self.accounts = accounts
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // A missing version identifies the original account store format.
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        activeAlias = try c.decodeIfPresent(String.self, forKey: .activeAlias)
        accounts = try c.decodeIfPresent([Account].self, forKey: .accounts) ?? []
    }
}

public struct AccountRemovalResult: Sendable, Equatable {
    public let removedAliases: [String]
    public let removedTelemetryIDs: [UUID]

    public init(removedAliases: [String] = [], removedTelemetryIDs: [UUID] = []) {
        self.removedAliases = removedAliases
        self.removedTelemetryIDs = removedTelemetryIDs
    }
}

public struct RotationResult: Sendable {
    public let next: Account?
    public let rotated: Bool
}

public actor AccountStore {
    private let url: URL
    private let clock: @Sendable () -> Date
    private var data: StoreData
    public private(set) var strategy: RotationStrategy
    /// Aliases currently assessed as draining from other users' activity (smart switch).
    private var drainingAliases: Set<String> = []
    /// Runtime-only confirmation times for drain observations. These are never
    /// persisted and let restricted polls expire an unrefreshed observation
    /// without clearing aliases that were not assessed.
    private var drainingObservedAt: [String: Date] = [:]
    /// Explicit user-selected runtime hold. This is deliberately not persisted.
    private var stickyAliasRuntime: String?
    /// Runtime latch for the account Smart Switch identified as actively draining.
    private var drainingHoldAlias: String?
    /// Cooling accounts that already rejected a Luna probe, keyed by retry time.
    private var lunaRejectedUntil: [String: Date] = [:]
    /// Reference-counted routing leases held by in-flight proxy or Task Board
    /// work. A lease defers automatic archival without changing the persisted
    /// pause timestamp; overlapping attempts on one alias remain protected
    /// until the final attempt releases its lease.
    private var routingLeases: [String: Int] = [:]
    /// Reservations made by atomic selection and waiting to be consumed by the
    /// corresponding attempt. These stay in-memory and are reference-counted.
    private var routingReservations: [String: Int] = [:]
    private static let historyCap = 64
    private static let currentSchemaVersion = 2
    public static let automaticArchiveDelay: TimeInterval = 604_800

    public init(
        url: URL = AppPaths.storeFile(),
        strategy: RotationStrategy = .priority,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.url = url
        self.clock = clock
        self.strategy = strategy
        var loaded = AccountStore.loadFrom(url) ?? StoreData()
        let migrationDate = clock()
        var needsMigration = loaded.schemaVersion < Self.currentSchemaVersion
        loaded.accounts = loaded.accounts.map { account in
            var normalized = account
            normalized.priority = max(0, account.priority)
            if normalized.telemetryID == Account.missingTelemetryID {
                normalized.telemetryID = UUID()
                needsMigration = true
            }
            if normalized.routingPausedAt == nil,
               normalized.archivedAt == nil,
               !normalized.routingEnabled {
                // Legacy paused accounts receive a deterministic grace period;
                // usage timestamps must never be used to backdate this value.
                normalized.routingPausedAt = migrationDate
                needsMigration = true
            }
            return normalized
        }
        if let activeAlias = loaded.activeAlias,
           !loaded.accounts.contains(where: { $0.alias == activeAlias && !$0.isArchived }) {
            // The active alias is part of the active-roster invariant. Clear stale
            // references left by a previous archive/removal instead of allowing a
            // historical record back into routing state.
            loaded.activeAlias = nil
            needsMigration = true
        }
        if loaded.schemaVersion < Self.currentSchemaVersion {
            loaded.schemaVersion = Self.currentSchemaVersion
            needsMigration = true
        }
        if !Self.hasDenseActiveRanks(loaded) {
            // Only repair legacy or malformed rank sets. A valid dense ranking is
            // user-owned state and must survive every process restart unchanged.
            Self.renumberRanks(&loaded)
            needsMigration = true
        }
        self.data = loaded
        if needsMigration { Self.persist(loaded, to: url) }
    }

    public func setStrategy(_ s: RotationStrategy) { strategy = s }

    // MARK: - Persistence

    private static func loadFrom(_ url: URL) -> StoreData? {
        guard let raw = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder.codex.decode(StoreData.self, from: raw)
    }

    private func persist(preservingRanking: Bool = true, preservingActiveAlias: Bool = true) {
        let encoder = JSONEncoder.codex
        _ = Self.withStoreLock(url) {
            var snapshot = data
            if let latest = Self.loadFrom(url) {
                if preservingRanking {
                    Self.mergePersistedRanking(into: &snapshot, from: latest)
                }
                if preservingActiveAlias {
                    snapshot.activeAlias = latest.activeAlias
                }
            }
            guard let raw = try? encoder.encode(snapshot) else { return }
            Self.persistUnlocked(raw, to: url)
            data = snapshot
        }
    }

    private static func persist(_ data: StoreData, to url: URL) {
        let encoder = JSONEncoder.codex
        guard let raw = try? encoder.encode(data) else { return }
        persist(raw, to: url)
    }

    private static func persist(_ raw: Data, to url: URL) {
        _ = withStoreLock(url) {
            persistUnlocked(raw, to: url)
        }
    }

    /// Serializes every account-store writer across the app and headless helper
    /// processes. The lock file is a stable 0600 sentinel; the descriptor owns
    /// the lock lifetime so a crashed process cannot strand it.
    @discardableResult
    private static func withStoreLock(_ url: URL, _ body: () -> Void) -> Bool {
        let fileManager = FileManager.default
        let dir = url.deletingLastPathComponent()
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let lockURL = dir.appendingPathComponent("." + url.lastPathComponent + ".lock")
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, mode_t(0o600))
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { return false }
        defer { _ = flock(descriptor, LOCK_UN) }
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: lockURL.path)
        body()
        return true
    }

    private static func persistUnlocked(_ raw: Data, to url: URL) {
        let fileManager = FileManager.default
        let dir = url.deletingLastPathComponent()
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let tmp = dir.appendingPathComponent(
            "." + url.lastPathComponent + ".tmp-" + UUID().uuidString
        )
        do {
            try raw.write(to: tmp, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
            if fileManager.fileExists(atPath: url.path) {
                _ = try fileManager.replaceItemAt(url, withItemAt: tmp)
            } else {
                try fileManager.moveItem(at: tmp, to: url)
            }
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            try? fileManager.removeItem(at: tmp)
        }
    }

    private static func mergePersistedRanking(into local: inout StoreData, from latest: StoreData) {
        for index in local.accounts.indices {
            let account = local.accounts[index]
            let latestAccount = latest.accounts.first {
                !account.accountID.isEmpty && !$0.accountID.isEmpty && $0.accountID == account.accountID
            } ?? latest.accounts.first { $0.alias == account.alias }
            if let latestAccount {
                local.accounts[index].priority = latestAccount.priority
            }
        }
    }

    private static func hasDenseActiveRanks(_ data: StoreData) -> Bool {
        let ranks = data.accounts
            .filter { !$0.isArchived }
            .map(\.priority)
        if ranks.isEmpty { return true }
        guard ranks.count == Set(ranks).count else { return false }
        return Set(ranks) == Set(1...ranks.count)
    }

    // MARK: - Reads

    public func all() -> [Account] { data.accounts }
    public func activeAlias() -> String? { data.activeAlias }
    public func stickyAlias() -> String? { stickyAliasRuntime }
    public func currentDrainingHoldAlias() -> String? { drainingHoldAlias }
    public func account(_ alias: String) -> Account? { data.accounts.first { $0.alias == alias } }

    /// Toggles the runtime-only menu hold. A held account remains selected while
    /// it is hard-eligible, regardless of displayed usage or in-flight leases.
    @discardableResult
    public func toggleStickyAlias(_ alias: String, now: Date = Date()) -> Bool {
        if stickyAliasRuntime == alias {
            stickyAliasRuntime = nil
            return true
        }
        guard let selected = account(alias), selected.isEligible(now: now) else { return false }
        stickyAliasRuntime = alias
        activate(alias, now: now)
        return true
    }

    private func clearStickyIfNeeded(_ alias: String) {
        if stickyAliasRuntime == alias { stickyAliasRuntime = nil }
    }

    private func clearRuntimeHolds(_ alias: String) {
        clearStickyIfNeeded(alias)
        if drainingHoldAlias == alias { drainingHoldAlias = nil }
        lunaRejectedUntil.removeValue(forKey: alias)
    }

    public func reserveLunaOpportunity(excluding alias: String? = nil, now: Date = Date()) -> Account? {
        lunaRejectedUntil = lunaRejectedUntil.filter { $0.value > now }
        let candidates = data.accounts.filter { account in
            account.alias != alias && account.isRoutableIgnoringCooldown
                && account.cooldownUntil(now: now) != nil
                && lunaRejectedUntil[account.alias] == nil
                && routingLeases[account.alias, default: 0] == 0
        }
        guard let selected = strategySorted(candidates, strategy: strategy).first else { return nil }
        reserveLease(selected.alias)
        touchLastUsed(selected.alias, now: now)
        return selected
    }

    public func recordLunaRejection(_ alias: String, until: Date) {
        lunaRejectedUntil[alias] = until
    }

    /// Returns the persisted instant at which a paused account becomes eligible for
    /// automatic archival. The later routed-use timestamp wins, so a request that
    /// was already in flight when routing was paused gets a full seven-day grace
    /// period from that attempt. Missing timestamps are never treated as due.
    public static func automaticArchiveDeadline(for account: Account) -> Date? {
        guard account.archivedAt == nil,
              !account.routingEnabled,
              let pausedAt = account.routingPausedAt else {
            return nil
        }
        let baseline = max(pausedAt, account.lastServedByUs ?? pausedAt)
        return baseline.addingTimeInterval(automaticArchiveDelay)
    }

    /// Acquires a lease for work that has already selected an account. Leases are
    /// intentionally in-memory runtime state and never alter account persistence.
    public func acquireRoutingLease(_ alias: String) {
        guard data.accounts.contains(where: { $0.alias == alias }) else { return }
        routingLeases[alias, default: 0] += 1
    }

    public func releaseRoutingLease(_ alias: String) {
        guard let count = routingLeases[alias] else { return }
        if count <= 1 {
            routingLeases.removeValue(forKey: alias)
        } else {
            routingLeases[alias] = count - 1
        }
    }

    /// Selects and leases an account in one actor transaction. This closes the
    /// selection-to-lease race when several proxy clients start at once.
    public func reserveCurrent(avoidingLeased: Bool = false, now: Date = Date()) -> Account? {
        guard let selected = current(now: now, avoidingLeased: avoidingLeased) else { return nil }
        reserveLease(selected.alias)
        return selected
    }

    public func reserveEligible(_ alias: String, now: Date = Date()) -> Account? {
        guard let selected = account(alias), selected.isEligible(now: now) else { return nil }
        reserveLease(alias)
        return selected
    }

    public func reserveBestEligible(
        among aliases: [String],
        excluding excludedAlias: String? = nil,
        primaryThreshold: Int = Int.max,
        secondaryThreshold: Int = Int.max,
        avoidingLeased: Bool = false,
        now: Date = Date()
    ) -> Account? {
        guard let selected = bestEligible(
            among: aliases.filter { $0 != excludedAlias },
            primaryThreshold: primaryThreshold,
            secondaryThreshold: secondaryThreshold,
            avoidingLeased: avoidingLeased,
            now: now
        ) else { return nil }
        reserveLease(selected.alias)
        touchLastUsed(selected.alias, now: now)
        return account(selected.alias)
    }

    private func reserveLease(_ alias: String) {
        acquireRoutingLease(alias)
        routingReservations[alias, default: 0] += 1
    }

    public func consumeRoutingReservation(_ alias: String) -> Bool {
        guard let count = routingReservations[alias], count > 0 else { return false }
        if count == 1 { routingReservations.removeValue(forKey: alias) }
        else { routingReservations[alias] = count - 1 }
        return true
    }

    public func routingLeaseAliases() -> Set<String> {
        Set(routingLeases.compactMap { alias, count in count > 0 ? alias : nil })
    }

    /// Archives every account whose persisted pause/use deadline has passed. The
    /// comparison is inclusive at exactly seven days. A supplied lease set is a
    /// snapshot for this transaction; when omitted, the store's active leases are
    /// used. Deferred accounts retain their pause timestamp unchanged.
    @discardableResult
    public func archiveDueAccounts(now: Date? = nil, leasedAliases: Set<String>? = nil) -> [Account] {
        let timestamp = now ?? clock()
        let leases = leasedAliases ?? routingLeaseAliases()
        let dueAliases = data.accounts.compactMap { account -> String? in
            guard !leases.contains(account.alias),
                  let deadline = Self.automaticArchiveDeadline(for: account),
                  timestamp >= deadline else {
                return nil
            }
            return account.alias
        }
        guard !dueAliases.isEmpty else { return [] }

        var archived: [Account] = []
        for alias in dueAliases {
            guard let i = index(alias), !data.accounts[i].isArchived else { continue }
            data.accounts[i].archivedAt = timestamp
            data.accounts[i].routingEnabled = false
            if data.activeAlias == alias { data.activeAlias = nil }
            clearRuntimeHolds(alias)
            drainingAliases.remove(alias)
            drainingObservedAt.removeValue(forKey: alias)
            archived.append(data.accounts[i])
        }
        guard !archived.isEmpty else { return [] }
        renumberRanks()
        persist(preservingRanking: false, preservingActiveAlias: false)
        return archived
    }

    /// Accounts in the operational roster, in their dense visible rank order.
    /// Routing-paused accounts remain active until they are explicitly archived.
    public func activeAccounts() -> [Account] {
        rankedAccounts(data.accounts.filter { !$0.isArchived })
    }

    /// Accounts retained for history and ownership, excluded from all active
    /// routing and quota consumers.
    public func archivedAccounts() -> [Account] {
        data.accounts
            .filter(\.isArchived)
            .sorted {
                switch ($0.archivedAt, $1.archivedAt) {
                case let (left?, right?) where left != right: return left > right
                case (nil, _?): return false
                case (_?, nil): return true
                default: return $0.alias < $1.alias
                }
            }
    }

    private func rankedAccounts(_ accounts: [Account]) -> [Account] {
        accounts.sorted {
            if $0.priority != $1.priority { return $0.priority > $1.priority }
            return Self.selectionOrder($0, $1, strategy: .priority)
        }
    }

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
        avoidingLeased: Bool = false,
        now: Date = Date()
    ) -> Account? {
        let allowed = Set(aliases)
        let eligible = data.accounts.filter { allowed.contains($0.alias) && $0.isEligible(now: now) }
        let unleased = eligible.filter { routingLeases[$0.alias, default: 0] == 0 }
        let ordered = strategySorted(
            avoidingLeased && !unleased.isEmpty ? unleased : eligible,
            strategy: strategy
        )
        return ordered.first {
            $0.isWithinRotationThresholds(primaryPercent: primaryThreshold, secondaryPercent: secondaryThreshold)
        } ?? ordered.first
    }

    private func eligibleOrdered(now: Date, excluding: String? = nil) -> [Account] {
        strategySorted(
            data.accounts.filter { $0.isEligible(now: now) && $0.alias != excluding },
            strategy: strategy
        )
    }

    // MARK: - Selection

    /// The account the proxy should use right now, applying the configured strategy and stickiness.
    /// New requests can avoid accounts that already have in-flight routed work so parallel
    /// clients do not pile onto one account before upstream quota can react.
    public func current(now: Date = Date(), avoidingLeased: Bool = false) -> Account? {
        if let stickyAliasRuntime {
            if let sticky = account(stickyAliasRuntime), sticky.isEligible(now: now) {
                if data.activeAlias != sticky.alias { activate(sticky.alias, now: now) }
                return sticky
            } else {
                self.stickyAliasRuntime = nil
            }
        }
        if let drainingHoldAlias {
            if let held = account(drainingHoldAlias), held.isEligible(now: now) {
                if data.activeAlias != held.alias { activate(held.alias, now: now) }
                return held
            } else {
                self.drainingHoldAlias = nil
            }
        }
        switch strategy {
        case .priority:
            let eligible = eligibleSorted(now: now)
            let unleased = eligible.filter { routingLeases[$0.alias, default: 0] == 0 }
            let ranked = avoidingLeased && !unleased.isEmpty ? unleased : eligible
            guard let best = ranked.first else { return nil }
            let hasEligibleDraining = ranked.contains { drainingAliases.contains($0.alias) }
            if let active = account(data.activeAlias ?? ""), active.isEligible(now: now),
               (!avoidingLeased || routingLeases[active.alias, default: 0] == 0),
               active.alias == best.alias ||
                (!hasEligibleDraining && active.priority == best.priority) {
                return active
            }
            activate(best.alias, now: now)
            return account(best.alias)
        case .roundRobin:
            let eligible = eligibleOrdered(now: now)
            let unleased = eligible.filter { routingLeases[$0.alias, default: 0] == 0 }
            let ordered = avoidingLeased && !unleased.isEmpty ? unleased : eligible
            guard let best = ordered.first else { return nil }
            let hasEligibleDraining = ordered.contains { drainingAliases.contains($0.alias) }
            if let active = account(data.activeAlias ?? ""), active.isEligible(now: now),
               (!avoidingLeased || routingLeases[active.alias, default: 0] == 0),
               (!hasEligibleDraining || active.alias == best.alias) {
                return active
            }
            activate(best.alias, now: now)
            return account(best.alias)
        }
    }

    private func activate(_ alias: String, now: Date) {
        data.activeAlias = alias
        if let i = index(alias) { data.accounts[i].lastUsedAt = now }
        persist(preservingActiveAlias: false)
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
        if let next = eligibleOrdered(now: now, excluding: data.activeAlias).first {
            activate(next.alias, now: now)
            return account(next.alias)
        }
        if let active = data.activeAlias, let acc = account(active), acc.isEligible(now: now) { return acc }
        return current(now: now)
    }

    /// Disable `alias` for `limit` until `resetAt`, then pick the next eligible account.
    public func rotateFrom(_ alias: String, limit: String, resetAt: Date?, now: Date = Date(), fallbackCooldown: TimeInterval) -> RotationResult {
        clearRuntimeHolds(alias)
        if let i = index(alias) {
            let until = resetAt ?? now.addingTimeInterval(fallbackCooldown)
            data.accounts[i].disabledUntil[limit] = until
        }
        let next: Account?
        switch strategy {
        case .priority:
            next = eligibleSorted(now: now).first { $0.alias != alias }
        case .roundRobin:
            next = eligibleOrdered(now: now, excluding: alias).first
        }
        guard let picked = next else { persist(); return RotationResult(next: nil, rotated: false) }
        activate(picked.alias, now: now)
        return RotationResult(next: account(picked.alias), rotated: true)
    }

    public func markLimited(_ alias: String, limit: String, resetAt: Date?, now: Date = Date(), fallbackCooldown: TimeInterval) {
        guard let i = index(alias) else { return }
        clearRuntimeHolds(alias)
        data.accounts[i].disabledUntil[limit] = resetAt ?? now.addingTimeInterval(fallbackCooldown)
        persist()
    }

    public func markNeedsLoginOnly(_ alias: String) {
        guard let i = index(alias) else { return }
        clearRuntimeHolds(alias)
        data.accounts[i].needsLogin = true
        drainingAliases.remove(alias)
        drainingObservedAt.removeValue(forKey: alias)
        persist()
    }

    public func markNeedsLogin(_ alias: String, now: Date = Date()) -> RotationResult {
        clearRuntimeHolds(alias)
        if let i = index(alias) { data.accounts[i].needsLogin = true }
        drainingAliases.remove(alias)
        drainingObservedAt.removeValue(forKey: alias)
        let next: Account?
        switch strategy {
        case .priority: next = eligibleSorted(now: now).first { $0.alias != alias }
        case .roundRobin: next = eligibleOrdered(now: now, excluding: alias).first
        }
        guard let picked = next else { persist(); return RotationResult(next: nil, rotated: false) }
        activate(picked.alias, now: now)
        return RotationResult(next: account(picked.alias), rotated: true)
    }

    /// Manual switch: clears the target's cooldowns and needs-login, then activates it.
    @discardableResult
    public func setActive(_ alias: String, now: Date = Date()) -> Account? {
        guard let i = index(alias), data.accounts[i].routingEnabled, !data.accounts[i].isArchived else { return nil }
        data.accounts[i].disabledUntil = [:]
        data.accounts[i].needsLogin = false
        data.accounts[i].routingPausedAt = nil
        data.accounts[i].lastUsedAt = now
        data.activeAlias = alias
        persist(preservingActiveAlias: false)
        return data.accounts[i]
    }

    /// Archive an account locally while retaining its credentials, managed-home ownership,
    /// usage history, and user preferences. Repeating the operation is a no-op.
    @discardableResult
    public func archive(alias: String, now: Date? = nil) -> Account? {
        guard let i = index(alias) else { return nil }
        var changed = false
        if !data.accounts[i].isArchived {
            let timestamp = now ?? clock()
            data.accounts[i].archivedAt = timestamp
            data.accounts[i].routingEnabled = false
            if data.accounts[i].routingPausedAt == nil {
                data.accounts[i].routingPausedAt = timestamp
            }
            changed = true
        } else {
            // Repair malformed/legacy archived rows without changing an existing
            // archive timestamp, keeping repeated archive calls idempotent.
            if data.accounts[i].routingEnabled {
                data.accounts[i].routingEnabled = false
                changed = true
            }
            if data.accounts[i].routingPausedAt == nil {
                data.accounts[i].routingPausedAt = now ?? clock()
                changed = true
            }
        }
        if data.activeAlias == alias {
            data.activeAlias = nil
            changed = true
        }
        clearRuntimeHolds(alias)
        if drainingAliases.remove(alias) != nil { changed = true }
        if drainingObservedAt.removeValue(forKey: alias) != nil { changed = true }
        if changed {
            renumberRanks()
            persist(preservingRanking: false, preservingActiveAlias: data.activeAlias != nil)
        }
        return data.accounts[i]
    }

    /// Restore an archived account to the bottom of the active ranking. It remains paused
    /// until the owner explicitly enables routing. Repeating restore is a no-op.
    @discardableResult
    public func restore(alias: String, now: Date? = nil) -> Account? {
        guard let i = index(alias) else { return nil }
        guard data.accounts[i].isArchived else { return data.accounts[i] }

        let timestamp = now ?? clock()
        data.accounts[i].archivedAt = nil
        data.accounts[i].routingEnabled = false
        data.accounts[i].routingPausedAt = timestamp
        drainingAliases.remove(alias)
        drainingObservedAt.removeValue(forKey: alias)

        let activeOthers = data.accounts.filter { !$0.isArchived && $0.alias != alias }
        let minimumRank = activeOthers.map(\.priority).min() ?? 1
        data.accounts[i].priority = minimumRank - 1
        renumberRanks()
        persist(preservingRanking: false)
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
            drainingAliases.remove(alias)
            drainingObservedAt.removeValue(forKey: alias)
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
        if clearNeedsLogin {
            data.accounts[i].needsLogin = false
            drainingAliases.remove(alias)
            drainingObservedAt.removeValue(forKey: alias)
        }
        persist()
    }

    public func updateUsage(_ alias: String, windows: [UsageWindow]) {
        guard let i = index(alias) else { return }
        // wham/usage always reports at least one window for an entitled account; a transient
        // empty response must not wipe a real reading off the display.
        if windows.isEmpty, !data.accounts[i].usage.isEmpty { return }
        let previousWindows = data.accounts[i].usage
        let resetLabels = Self.usageResetOrDecreaseLabels(previous: previousWindows, current: windows)
        if !resetLabels.isEmpty {
            drainingAliases.remove(alias)
            drainingObservedAt.removeValue(forKey: alias)
            data.accounts[i].usageHistory = (data.accounts[i].usageHistory ?? []).filter {
                !resetLabels.contains($0.label)
            }
        }
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
        let capturedAt = clock()
        let samples = windows.map {
            WindowSample(
                capturedAt: capturedAt,
                label: $0.label,
                usedPercent: $0.usedPercent,
                resetAt: $0.resetAt
            )
        }
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
        cacheWriteInputTokens: Int = 0,
        outputTokens: Int,
        cachedInputPresence: TokenFieldPresence = .present,
        cacheWriteInputPresence: TokenFieldPresence? = nil
    ) {
        guard let i = index(alias) else { return }
        var stats = data.accounts[i].usageStats ?? UsageStats()
        stats.accumulate(
            model: model,
            inputTokens: inputTokens,
            cachedInputTokens: cachedInputTokens,
            cacheWriteInputTokens: cacheWriteInputTokens,
            outputTokens: outputTokens,
            cachedInputPresence: cachedInputPresence,
            cacheWriteInputPresence: cacheWriteInputPresence
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
        if aliases.isEmpty {
            drainingObservedAt.removeAll()
            drainingHoldAlias = nil
            return
        }
        if drainingHoldAlias == nil {
            drainingHoldAlias = data.activeAlias.flatMap { aliases.contains($0) ? $0 : nil }
                ?? aliases.sorted().first
        }
        let observedAt = clock()
        drainingObservedAt = Dictionary(uniqueKeysWithValues: aliases.map { alias in
            (alias, drainingObservedAt[alias] ?? observedAt)
        })
    }

    public func currentDrainingAliases() -> Set<String> { drainingAliases }

    /// Merges assessments from one usage poll into the runtime-only drain state.
    /// Aliases omitted from a restricted poll remain observed until expiry.
    public func mergeDrainingAssessments(
        _ assessments: [DrainAssessment],
        assessedAt: Date = Date(),
        lookbackSeconds: TimeInterval = SmartSwitchPolicy.lookbackSeconds
    ) {
        for assessment in assessments {
            guard let account = account(assessment.alias), !account.isArchived else {
                drainingAliases.remove(assessment.alias)
                drainingObservedAt.removeValue(forKey: assessment.alias)
                continue
            }
            if assessment.isDraining {
                drainingAliases.insert(assessment.alias)
                drainingObservedAt[assessment.alias] = assessedAt
                if drainingHoldAlias == nil {
                    drainingHoldAlias = assessment.alias
                }
            } else {
                drainingAliases.remove(assessment.alias)
                drainingObservedAt.removeValue(forKey: assessment.alias)
            }
        }
        expireDrainingObservations(now: assessedAt, lookbackSeconds: lookbackSeconds)
    }

    public func expireDrainingObservations(
        now: Date = Date(),
        lookbackSeconds: TimeInterval = SmartSwitchPolicy.lookbackSeconds
    ) {
        let expired = drainingObservedAt.compactMap { alias, observedAt -> String? in
            now.timeIntervalSince(observedAt) >= lookbackSeconds ? alias : nil
        }
        for alias in expired {
            drainingObservedAt.removeValue(forKey: alias)
            drainingAliases.remove(alias)
        }
    }

    public func clearDrainingObservation(_ alias: String) {
        drainingAliases.remove(alias)
        drainingObservedAt.removeValue(forKey: alias)
    }

    private static func usageResetOrDecreaseLabels(previous: [UsageWindow], current: [UsageWindow]) -> Set<String> {
        let oldByLabel = Dictionary(uniqueKeysWithValues: previous.map { ($0.label, $0) })
        let currentLabels = Set(current.map(\.label))
        var changed = Set(previous.filter { !currentLabels.contains($0.label) }.map(\.label))
        for window in current {
            guard let old = oldByLabel[window.label] else { continue }
            if old.resetAt != window.resetAt || window.usedPercent < old.usedPercent {
                changed.insert(window.label)
            }
        }
        return changed
    }

    /// Applies a complete ranking (top first) to the active roster. Archived accounts
    /// are intentionally outside this visible rank sequence.
    public func applyRanking(_ orderedAliases: [String]) {
        let activeAliases = Set(data.accounts.filter { !$0.isArchived }.map(\.alias))
        guard orderedAliases.count == activeAliases.count,
              Set(orderedAliases) == activeAliases else { return }
        let count = orderedAliases.count
        for (position, alias) in orderedAliases.enumerated() {
            if let i = index(alias) {
                data.accounts[i].priority = count - position
            }
        }
        persist(preservingRanking: false)
    }

    /// Moves an active account within the priority-sorted ranking and renumbers every rank
    /// densely so the change is always visible. `toIndex` is a position where 0 is top.
    public func reorderAccount(_ alias: String, toIndex target: Int) {
        let ranked = data.accounts
            .filter { !$0.isArchived }
            .sorted { Self.selectionOrder($0, $1, strategy: .priority) }
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
        persist(preservingRanking: false)
    }

    public func setPriority(_ alias: String, priority: Int) {
        guard let i = index(alias) else { return }
        // Legacy numeric setter: keep the value in a sane range, then renumber so the
        // ranking stays dense and every rank change stays visible.
        data.accounts[i].priority = max(0, priority)
        renumberRanks()
        persist(preservingRanking: false)
    }

    /// Rewrites active priorities to dense ordinals (N…1), leaving archived records out of
    /// the visible ranking sequence.
    nonisolated private static func renumberRanks(_ data: inout StoreData) {
        let ranked = data.accounts
            .filter { !$0.isArchived }
            .sorted { selectionOrder($0, $1, strategy: .priority) }
        let count = ranked.count
        guard count > 0 else { return }
        var newPriorities: [String: Int] = [:]
        for (position, entry) in ranked.enumerated() {
            newPriorities[entry.alias] = count - position
        }
        for i in data.accounts.indices where !data.accounts[i].isArchived {
            data.accounts[i].priority = newPriorities[data.accounts[i].alias] ?? data.accounts[i].priority
        }
    }

    private func renumberRanks() {
        Self.renumberRanks(&data)
    }

    @discardableResult
    public func remove(_ alias: String) -> UUID? {
        let removedTelemetryID = data.accounts.first(where: { $0.alias == alias })?.telemetryID
        data.accounts.removeAll { $0.alias == alias }
        if data.activeAlias == alias { data.activeAlias = nil }
        clearRuntimeHolds(alias)
        drainingAliases.remove(alias)
        drainingObservedAt.removeValue(forKey: alias)
        renumberRanks()
        persist(preservingRanking: false, preservingActiveAlias: false)
        return removedTelemetryID
    }

    /// Permanent removal result used by the later telemetry purge hook. The archive path
    /// never calls this operation.
    @discardableResult
    public func removeWithTelemetry(_ alias: String) -> AccountRemovalResult {
        guard let account = data.accounts.first(where: { $0.alias == alias }) else {
            return AccountRemovalResult()
        }
        _ = remove(alias)
        return AccountRemovalResult(removedAliases: [account.alias], removedTelemetryIDs: [account.telemetryID])
    }

    /// Drop CodexBar-managed accounts whose accountID is no longer in CodexBar's roster.
    /// Non-managed accounts (e.g. imported from live auth.json) are left untouched.
    @discardableResult
    public func reconcileManaged(present: Set<String>) -> [String] {
        reconcileManagedWithTelemetry(present: present).removedAliases
    }

    /// Reconcile CodexBar's managed roster while returning stable telemetry IDs for a
    /// subsequent scoped purge. Non-managed accounts are intentionally left untouched.
    @discardableResult
    public func reconcileManagedWithTelemetry(present: Set<String>) -> AccountRemovalResult {
        let removedAccounts = data.accounts.filter {
            $0.managedHomePath != nil && !present.contains($0.accountID)
        }
        guard !removedAccounts.isEmpty else { return AccountRemovalResult() }
        let removed = Set(removedAccounts.map(\.alias))
        data.accounts.removeAll { removed.contains($0.alias) }
        if let active = data.activeAlias, removed.contains(active) { data.activeAlias = nil }
        if let stickyAliasRuntime, removed.contains(stickyAliasRuntime) { self.stickyAliasRuntime = nil }
        if let drainingHoldAlias, removed.contains(drainingHoldAlias) { self.drainingHoldAlias = nil }
        for alias in removed { lunaRejectedUntil.removeValue(forKey: alias) }
        drainingAliases.subtract(removed)
        for alias in removed { drainingObservedAt.removeValue(forKey: alias) }
        renumberRanks()
        persist(preservingRanking: false, preservingActiveAlias: false)
        return AccountRemovalResult(
            removedAliases: removedAccounts.map(\.alias),
            removedTelemetryIDs: removedAccounts.map(\.telemetryID)
        )
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
            merged.archivedAt = data.accounts[i].archivedAt
            merged.routingPausedAt = data.accounts[i].routingPausedAt
            merged.telemetryID = data.accounts[i].telemetryID == Account.missingTelemetryID
                ? UUID()
                : data.accounts[i].telemetryID
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
            let usageResetLabels = Self.usageResetOrDecreaseLabels(
                previous: data.accounts[i].usage,
                current: merged.usage
            )
            data.accounts[i] = merged
            if !usageResetLabels.isEmpty {
                drainingAliases.remove(merged.alias)
                drainingObservedAt.removeValue(forKey: merged.alias)
                data.accounts[i].usageHistory = (data.accounts[i].usageHistory ?? []).filter {
                    !usageResetLabels.contains($0.label)
                }
            }
            if data.accounts[i].routingPausedAt == nil,
               data.accounts[i].archivedAt == nil,
               !data.accounts[i].routingEnabled {
                data.accounts[i].routingPausedAt = clock()
            }
            persist()
            return data.accounts[i]
        }
        if account.telemetryID == Account.missingTelemetryID {
            account.telemetryID = UUID()
        }
        if account.routingPausedAt == nil, account.archivedAt == nil, !account.routingEnabled {
            account.routingPausedAt = clock()
        }
        data.accounts.append(account)
        // Newcomers enter at the BOTTOM of the ranking: their raw priority comes from an
        // incompatible scale (legacy 0–10, CodexBar rosters), so comparing it against the
        // dense ranks would scramble ordering. Rank changes belong to the ranking editor.
        let minimumRank = data.accounts.filter { !$0.isArchived }.map(\.priority).min() ?? 2
        if let i = index(account.alias) {
            data.accounts[i].priority = minimumRank - 1
        }
        renumberRanks()
        persist(preservingRanking: false)
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

    public func setRoutingEnabled(_ alias: String, enabled: Bool, now: Date? = nil) {
        guard let i = index(alias) else { return }
        if data.accounts[i].isArchived, enabled { return }
        let wasEnabled = data.accounts[i].routingEnabled
        data.accounts[i].routingEnabled = enabled
        if enabled {
            data.accounts[i].routingPausedAt = nil
            drainingAliases.remove(alias)
            drainingObservedAt.removeValue(forKey: alias)
        } else if wasEnabled {
            data.accounts[i].routingPausedAt = now ?? clock()
            drainingAliases.remove(alias)
            drainingObservedAt.removeValue(forKey: alias)
        } else if data.accounts[i].routingPausedAt == nil {
            data.accounts[i].routingPausedAt = now ?? clock()
            drainingAliases.remove(alias)
            drainingObservedAt.removeValue(forKey: alias)
        }
        if !enabled, data.activeAlias == alias { data.activeAlias = nil }
        if !enabled { clearRuntimeHolds(alias) }
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
