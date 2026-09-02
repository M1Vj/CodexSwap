import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

struct StoreData: Codable {
    var schemaVersion: Int = 2
    var activeAlias: String?
    /// Persisted control-plane sticky selection.  The menu UI still treats the
    /// value as runtime state, but persisting it lets a separate agent CLI
    /// process hand the selection to the live app safely.
    var stickyAlias: String?
    /// True only when the sticky account was explicitly pinned after reaching a
    /// configured usage cap. It is coupled to `stickyAlias` and cleared with it.
    var stickyUsageLimitOverride: Bool
    var accounts: [Account] = []

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, activeAlias, stickyAlias, stickyUsageLimitOverride, accounts
    }

    init(
        schemaVersion: Int = 2,
        activeAlias: String? = nil,
        stickyAlias: String? = nil,
        stickyUsageLimitOverride: Bool = false,
        accounts: [Account] = []
    ) {
        self.schemaVersion = schemaVersion
        self.activeAlias = activeAlias
        self.stickyAlias = stickyAlias
        self.stickyUsageLimitOverride = stickyUsageLimitOverride
        self.accounts = accounts
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // A missing version identifies the original account store format.
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        activeAlias = try c.decodeIfPresent(String.self, forKey: .activeAlias)
        stickyAlias = try c.decodeIfPresent(String.self, forKey: .stickyAlias)
        stickyUsageLimitOverride = try c.decodeIfPresent(Bool.self, forKey: .stickyUsageLimitOverride) ?? false
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

/// Internal filesystem seam used by the atomic usage-limit transaction. The
/// production initializer supplies AccountStore's throwing atomic writer;
/// tests can inject a deterministic failure without changing file permissions
/// or touching a user-owned store.
typealias AccountStorePersistenceWriter = @Sendable (Data, URL) throws -> Void

private enum AccountStorePersistenceError: Error {
    case verificationFailed
}

/// Result of a usage-limit write that validates its confirmation requirement
/// against the latest persisted control-plane state while holding the store
/// lock. The CLI maps these cases to its stable, sanitized envelope.
public enum AccountUsageLimitWriteResult: Sendable {
    case updated(Account)
    case confirmationRequired(Account)
    case accountNotFound
    case persistenceFailed
}

public actor AccountStore {
    private let url: URL
    private let clock: @Sendable () -> Date
    private let persistenceWriter: AccountStorePersistenceWriter
    private var data: StoreData
    /// The last document this actor loaded or successfully persisted. A write
    /// can be based on an older in-memory snapshot when another process has
    /// updated the file, so persistence compares the current document with
    /// this baseline and applies only fields changed by this actor to the
    /// latest locked document.
    private var persistedData: StoreData
    private var persistedModificationDate: Date?
    public private(set) var strategy: RotationStrategy
    /// Aliases currently assessed as draining from other users' activity (smart switch).
    private var drainingAliases: Set<String> = []
    /// Runtime-only confirmation times for drain observations. These are never
    /// persisted and let restricted polls expire an unrefreshed observation
    /// without clearing aliases that were not assessed.
    private var drainingObservedAt: [String: Date] = [:]
    /// Explicit user-selected runtime hold. This is deliberately not persisted.
    private var stickyAliasRuntime: String?
    /// Coupled to the persisted sticky alias. A true value means the user
    /// explicitly pinned an account after it crossed its usage cap.
    private var stickyUsageLimitOverrideRuntime = false
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
        self.init(
            url: url,
            strategy: strategy,
            clock: clock,
            persistenceWriter: { raw, target in
                try Self.persistUnlockedThrowing(raw, to: target)
            }
        )
    }

    /// Internal initializer reserved for deterministic persistence-failure
    /// tests. Production callers use the public initializer above.
    init(
        url: URL = AppPaths.storeFile(),
        strategy: RotationStrategy = .priority,
        clock: @escaping @Sendable () -> Date = { Date() },
        persistenceWriter: @escaping AccountStorePersistenceWriter
    ) {
        self.url = url
        self.clock = clock
        self.persistenceWriter = persistenceWriter
        self.strategy = strategy
        var loaded = AccountStore.loadFrom(url) ?? StoreData()
        let migrationDate = clock()
        var needsMigration = loaded.schemaVersion < Self.currentSchemaVersion
        if loaded.stickyAlias == nil, loaded.stickyUsageLimitOverride {
            // Older builds could persist the override bit after removing its
            // alias. Repair the coupled control-plane fields on reload.
            loaded.stickyUsageLimitOverride = false
            needsMigration = true
        }
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
        self.persistedData = loaded
        self.persistedModificationDate = Self.modificationDate(for: url)
        self.stickyAliasRuntime = loaded.stickyAlias
        self.stickyUsageLimitOverrideRuntime = loaded.stickyUsageLimitOverride && loaded.stickyAlias != nil
        if needsMigration { Self.persist(loaded, to: url) }
    }

    public func setStrategy(_ s: RotationStrategy) {
        refreshExternalStateIfNeeded()
        strategy = s
    }

    /// Picks up account/routing/sticky changes made by another CodexSwap
    /// process (notably the agent CLI) without disturbing in-memory leases.
    /// AccountStore remains the sole writer; this is a read-side handoff.
    private func refreshExternalStateIfNeeded() {
        let currentDate = Self.modificationDate(for: url)
        guard currentDate != persistedModificationDate,
              var loaded = Self.loadFrom(url) else { return }
        let needsStickyOverrideRepair = loaded.stickyAlias == nil && loaded.stickyUsageLimitOverride
        if needsStickyOverrideRepair {
            loaded.stickyUsageLimitOverride = false
        }
        data = loaded
        persistedData = loaded
        persistedModificationDate = currentDate
        stickyAliasRuntime = loaded.stickyAlias
        stickyUsageLimitOverrideRuntime = loaded.stickyUsageLimitOverride && loaded.stickyAlias != nil
        if needsStickyOverrideRepair {
            persist(repairingStickyUsageLimitOverride: true)
            stickyAliasRuntime = data.stickyAlias
            stickyUsageLimitOverrideRuntime = data.stickyUsageLimitOverride && data.stickyAlias != nil
        }
    }

    private static func modificationDate(for url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
    }

    // MARK: - Persistence

    private static func loadFrom(_ url: URL) -> StoreData? {
        guard let raw = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder.codex.decode(StoreData.self, from: raw)
    }

    private func persist(
        preservingRanking: Bool = true,
        preservingActiveAlias: Bool = true,
        preservingStickyAlias: Bool = true,
        clearingActiveAliases: Set<String> = [],
        repairingStickyUsageLimitOverride: Bool = false
    ) {
        let encoder = JSONEncoder.codex
        _ = Self.withStoreLock(url) {
            let latest = Self.loadFrom(url)
            var snapshot = Self.mergePersistedChanges(
                local: data,
                baseline: persistedData,
                latest: latest,
                preservingRanking: preservingRanking,
                preservingActiveAlias: preservingActiveAlias,
                preservingStickyAlias: preservingStickyAlias,
                clearingActiveAliases: clearingActiveAliases
            )
            if repairingStickyUsageLimitOverride, snapshot.stickyAlias == nil {
                snapshot.stickyUsageLimitOverride = false
            }
            guard let raw = try? encoder.encode(snapshot) else { return }
            // JSON's ISO-8601 encoding intentionally drops sub-second Date
            // precision. Keep only the merge baseline in the same canonical
            // form as the bytes on disk; the actor's public in-memory snapshot
            // must retain exact dates returned by its mutation APIs.
            let committed = (try? JSONDecoder.codex.decode(StoreData.self, from: raw)) ?? snapshot
            Self.persistUnlocked(raw, to: url)
            data = snapshot
            persistedData = committed
            persistedModificationDate = Self.modificationDate(for: url)
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
        try? persistUnlockedThrowing(raw, to: url)
    }

    /// Performs the same-directory temporary-file write and atomic replacement
    /// while preserving errors for callers that need to report a failed
    /// transaction. The legacy non-throwing path above intentionally retains
    /// its historical best-effort behavior.
    private static func persistUnlockedThrowing(_ raw: Data, to url: URL) throws {
        let fileManager = FileManager.default
        let dir = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
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
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            try? fileManager.removeItem(at: tmp)
            throw error
        }
    }

    private func persistAtomically(_ raw: Data) throws {
        try persistenceWriter(raw, url)
        guard let persisted = try? Data(contentsOf: url), persisted == raw else {
            throw AccountStorePersistenceError.verificationFailed
        }
    }

    /// Merges a stale actor's changed fields onto the newest document while the
    /// caller holds the store lock. The old implementation started from the
    /// actor's whole `data` value and preserved only a few special fields,
    /// allowing stale token/usage writes to roll back newer routing state. This
    /// merge treats the actor's last loaded document as a three-way baseline:
    /// unchanged local fields come from `latest`, while changed local fields
    /// carry the actor's explicit mutation forward.
    private static func mergePersistedChanges(
        local: StoreData,
        baseline: StoreData,
        latest: StoreData?,
        preservingRanking: Bool,
        preservingActiveAlias: Bool,
        preservingStickyAlias: Bool,
        clearingActiveAliases: Set<String>
    ) -> StoreData {
        guard let latest else { return local }
        var merged = latest

        if !preservingActiveAlias {
            merged.activeAlias = mergeValue(
                local.activeAlias,
                baseline: baseline.activeAlias,
                latest: latest.activeAlias
            )
        }
        if !clearingActiveAliases.isEmpty {
            merged.activeAlias = Self.activeAliasAfterClearing(
                latest: latest,
                baseline: baseline,
                clearing: clearingActiveAliases
            )
        }

        if !preservingStickyAlias {
            merged.stickyAlias = mergeValue(
                local.stickyAlias,
                baseline: baseline.stickyAlias,
                latest: latest.stickyAlias
            )
            merged.stickyUsageLimitOverride = mergeValue(
                local.stickyUsageLimitOverride,
                baseline: baseline.stickyUsageLimitOverride,
                latest: latest.stickyUsageLimitOverride
            )
        }
        if merged.stickyAlias == nil {
            // The override bit is coupled to its alias. Preserve this invariant
            // even when a stale writer clears only one side of the pair.
            merged.stickyUsageLimitOverride = false
        }

        merged.accounts = mergePersistedAccounts(
            local: local.accounts,
            baseline: baseline.accounts,
            latest: latest.accounts,
            preservingRanking: preservingRanking
        )
        return merged
    }

    /// A three-way field merge. A field changed by only one writer carries
    /// forward; when both writers changed it, the document read under the
    /// lock is newer and wins the conflict.
    private static func mergeValue<Value: Equatable>(
        _ local: Value,
        baseline: Value,
        latest: Value
    ) -> Value {
        if local == baseline { return latest }
        if latest == baseline { return local }
        return latest
    }

    private static func mergePersistedAccounts(
        local: [Account],
        baseline: [Account],
        latest: [Account],
        preservingRanking: Bool
    ) -> [Account] {
        let localBaseline = pairAccounts(baseline, with: local)
        let latestBaseline = pairAccounts(baseline, with: latest)
        var consumedLocal = Set<Int>()
        var result: [Account] = []

        for latestIndex in latest.indices {
            let latestAccount = latest[latestIndex]
            if let baselineIndex = latestBaseline.firstIndex(of: latestIndex) {
                // The local writer removed a baseline row. Keep that removal;
                // never reintroduce an account another writer intentionally
                // deleted from its own snapshot. If the latest writer changed
                // the row instead of deleting it, its newer row wins over the
                // stale removal.
                guard let localIndex = localBaseline[baselineIndex] else {
                    if latestAccount != baseline[baselineIndex] {
                        result.append(latestAccount)
                    }
                    continue
                }
                consumedLocal.insert(localIndex)
                result.append(
                    mergePersistedAccount(
                        local: local[localIndex],
                        baseline: baseline[baselineIndex],
                        latest: latestAccount,
                        preservingRanking: preservingRanking
                    )
                )
                continue
            }

            // This row was added after the baseline. If both writers added the
            // same stable account, keep the locked document as the winner;
            // otherwise retain the latest writer's new row unchanged.
            if let localIndex = local.indices.first(where: {
                !consumedLocal.contains($0)
                    && !localBaseline.contains($0)
                    && accountsMatch(local[$0], latestAccount)
            }) {
                consumedLocal.insert(localIndex)
            }
            result.append(latestAccount)
        }

        // Append accounts added only by this actor. Rows that were in the
        // baseline but disappeared from `latest` are deliberately omitted.
        for localIndex in local.indices where !localBaseline.contains(localIndex)
                                           && !consumedLocal.contains(localIndex) {
            let localAccount = local[localIndex]
            // Aliases are user-facing keys and must remain unique even when an
            // external writer replaced an account with a new stable identity.
            guard !latest.contains(where: {
                accountsMatch($0, localAccount) || $0.alias == localAccount.alias
            }) else { continue }
            result.append(localAccount)
        }
        return result
    }

    /// Applies an explicit active-alias clear without clearing a newer account
    /// that reused the same user-facing alias after the stale writer's snapshot.
    private static func activeAliasAfterClearing(
        latest: StoreData,
        baseline: StoreData,
        clearing aliases: Set<String>
    ) -> String? {
        guard let activeAlias = latest.activeAlias,
              aliases.contains(activeAlias) else {
            return latest.activeAlias
        }
        guard let baselineAccount = baseline.accounts.first(where: { $0.alias == activeAlias }) else {
            return nil
        }
        guard let latestAccount = latest.accounts.first(where: { $0.alias == activeAlias }) else {
            return nil
        }
        // A stale removal/archive may clear an active alias only when the
        // latest row is still exactly the baseline row. If the newer writer
        // changed or replaced that row, its active selection is newer state
        // and must win the conflict.
        return latestAccount == baselineAccount ? nil : activeAlias
    }

    /// Returns, for each reference row, the unique candidate index that
    /// represents it, or nil when that writer removed the row.
    private static func pairAccounts(_ reference: [Account], with candidates: [Account]) -> [Int?] {
        var consumed = Set<Int>()
        return reference.map { account in
            guard let index = candidates.indices
                .filter({ !consumed.contains($0) && accountsMatch(account, candidates[$0]) })
                .sorted(by: { accountMatchStrength(account, candidates[$0]) > accountMatchStrength(account, candidates[$1]) })
                .first else {
                return nil
            }
            consumed.insert(index)
            return index
        }
    }

    private static func accountMatchStrength(_ lhs: Account, _ rhs: Account) -> Int {
        if !lhs.accountID.isEmpty && !rhs.accountID.isEmpty && lhs.accountID == rhs.accountID { return 3 }
        if lhs.telemetryID != Account.missingTelemetryID,
           rhs.telemetryID != Account.missingTelemetryID,
           lhs.telemetryID == rhs.telemetryID { return 2 }
        if lhs.accountID.isEmpty || rhs.accountID.isEmpty { return lhs.alias == rhs.alias ? 1 : 0 }
        return 0
    }

    private static func mergePersistedAccount(
        local: Account,
        baseline: Account,
        latest: Account,
        preservingRanking: Bool
    ) -> Account {
        var merged = latest
        merged.alias = mergeValue(local.alias, baseline: baseline.alias, latest: latest.alias)
        merged.email = mergeValue(local.email, baseline: baseline.email, latest: latest.email)
        merged.accountID = mergeValue(local.accountID, baseline: baseline.accountID, latest: latest.accountID)
        merged.planType = mergeValue(local.planType, baseline: baseline.planType, latest: latest.planType)
        merged.accessToken = mergeValue(local.accessToken, baseline: baseline.accessToken, latest: latest.accessToken)
        merged.refreshToken = mergeValue(local.refreshToken, baseline: baseline.refreshToken, latest: latest.refreshToken)
        merged.idToken = mergeValue(local.idToken, baseline: baseline.idToken, latest: latest.idToken)
        if !preservingRanking {
            merged.priority = mergeValue(local.priority, baseline: baseline.priority, latest: latest.priority)
        }
        merged.disabledUntil = mergeCooldowns(
            local: local.disabledUntil,
            baseline: baseline.disabledUntil,
            latest: latest.disabledUntil
        )
        merged.needsLogin = mergeValue(local.needsLogin, baseline: baseline.needsLogin, latest: latest.needsLogin)
        merged.lastUsedAt = mergeValue(local.lastUsedAt, baseline: baseline.lastUsedAt, latest: latest.lastUsedAt)
        merged.usage = mergeUsageWindows(local: local.usage, baseline: baseline.usage, latest: latest.usage)
        merged.managedHomePath = mergeValue(local.managedHomePath, baseline: baseline.managedHomePath, latest: latest.managedHomePath)
        merged.routingEnabled = mergeValue(local.routingEnabled, baseline: baseline.routingEnabled, latest: latest.routingEnabled)
        merged.usageStats = mergeValue(local.usageStats, baseline: baseline.usageStats, latest: latest.usageStats)
        merged.usageHistory = mergeValue(local.usageHistory, baseline: baseline.usageHistory, latest: latest.usageHistory)
        merged.lastServedByUs = mergeValue(local.lastServedByUs, baseline: baseline.lastServedByUs, latest: latest.lastServedByUs)
        merged.archivedAt = mergeValue(local.archivedAt, baseline: baseline.archivedAt, latest: latest.archivedAt)
        merged.routingPausedAt = mergeValue(local.routingPausedAt, baseline: baseline.routingPausedAt, latest: latest.routingPausedAt)
        merged.telemetryID = mergeValue(local.telemetryID, baseline: baseline.telemetryID, latest: latest.telemetryID)
        merged.usageLimitSettings = mergeValue(
            local.usageLimitSettings,
            baseline: baseline.usageLimitSettings,
            latest: latest.usageLimitSettings
        )
        return merged
    }

    private static func mergeCooldowns(
        local: [String: Date],
        baseline: [String: Date],
        latest: [String: Date]
    ) -> [String: Date] {
        let keys = Set(local.keys).union(baseline.keys).union(latest.keys)
        var merged: [String: Date] = [:]
        for key in keys {
            let value = mergeValue(local[key], baseline: baseline[key], latest: latest[key])
            if let value { merged[key] = value }
        }
        return merged
    }

    private static func mergeUsageWindows(
        local: [UsageWindow],
        baseline: [UsageWindow],
        latest: [UsageWindow]
    ) -> [UsageWindow] {
        let localByKey = Dictionary(uniqueKeysWithValues: local.map { (usageWindowIdentity($0), $0) })
        let baselineByKey = Dictionary(uniqueKeysWithValues: baseline.map { (usageWindowIdentity($0), $0) })
        let latestByKey = Dictionary(uniqueKeysWithValues: latest.map { (usageWindowIdentity($0), $0) })
        let keys = Set(localByKey.keys).union(baselineByKey.keys).union(latestByKey.keys)
        var selected: [String: UsageWindow] = [:]
        for key in keys {
            guard let value = mergeValue(localByKey[key], baseline: baselineByKey[key], latest: latestByKey[key]) else {
                continue
            }
            selected[key] = value
        }
        var merged = latest.compactMap { selected.removeValue(forKey: usageWindowIdentity($0)) }
        merged.append(contentsOf: local.compactMap { selected.removeValue(forKey: usageWindowIdentity($0)) })
        return merged
    }

    private static func accountsMatch(_ lhs: Account, _ rhs: Account) -> Bool {
        if !lhs.accountID.isEmpty && !rhs.accountID.isEmpty {
            if lhs.accountID == rhs.accountID { return true }
            if lhs.telemetryID != Account.missingTelemetryID,
               rhs.telemetryID != Account.missingTelemetryID,
               lhs.telemetryID == rhs.telemetryID { return true }
            return false
        }
        if lhs.telemetryID != Account.missingTelemetryID,
           rhs.telemetryID != Account.missingTelemetryID,
           lhs.telemetryID == rhs.telemetryID { return true }
        return lhs.alias == rhs.alias
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

    public func all() -> [Account] { refreshExternalStateIfNeeded(); return data.accounts }
    public func activeAlias() -> String? { refreshExternalStateIfNeeded(); return data.activeAlias }
    public func stickyAlias() -> String? { refreshExternalStateIfNeeded(); return stickyAliasRuntime }
    public func stickyUsageLimitOverride() -> Bool {
        refreshExternalStateIfNeeded()
        return stickyAliasRuntime != nil && stickyUsageLimitOverrideRuntime
    }
    public func currentDrainingHoldAlias() -> String? { refreshExternalStateIfNeeded(); return drainingHoldAlias }
    public func account(_ alias: String) -> Account? { refreshExternalStateIfNeeded(); return data.accounts.first { $0.alias == alias } }

    /// Applies user-owned per-account usage caps. A currently sticky account
    /// that becomes capped loses a pre-cap sticky selection; a sticky account
    /// explicitly pinned after the cap remains an override until unpinned or a
    /// provider limit error clears it.
    @discardableResult
    public func setUsageLimitSettings(
        _ alias: String,
        settings: AccountUsageLimitSettings
    ) -> Account? {
        refreshExternalStateIfNeeded()
        guard let i = index(alias) else { return nil }
        data.accounts[i].usageLimitSettings = settings
        var stickyCleared = false
        if stickyAliasRuntime == alias,
           !stickyUsageLimitOverrideRuntime,
           data.accounts[i].isUsageLimitReached {
            stickyCleared = clearStickyIfNeeded(alias)
        }
        persist(
            preservingStickyAlias: !stickyCleared
        )
        return data.accounts[i]
    }

    /// Validates and persists a usage-limit update as one interprocess
    /// transaction. The latest account usage, active alias, and coupled sticky
    /// override are loaded only after acquiring the shared lock, so a CLI
    /// snapshot cannot bypass the confirmation requirement when another store
    /// changes state between projection and write.
    @discardableResult
    public func setUsageLimitSettingsAtomically(
        _ alias: String,
        settings: AccountUsageLimitSettings,
        confirming: Bool
    ) -> AccountUsageLimitWriteResult {
        var result: AccountUsageLimitWriteResult = .persistenceFailed
        let didLock = Self.withStoreLock(url) {
            guard var latest = Self.loadFrom(url) else {
                result = .accountNotFound
                return
            }
            guard let index = latest.accounts.firstIndex(where: { $0.alias == alias }) else {
                result = .accountNotFound
                return
            }

            let existing = latest.accounts[index]
            var projected = existing
            projected.usageLimitSettings = settings
            let hasStickyUsageLimitOverride = latest.stickyAlias == alias
                && latest.stickyUsageLimitOverride
            let immediatelyPausesCurrent = latest.activeAlias == alias
                && !hasStickyUsageLimitOverride
                && !existing.isUsageLimitReached
                && projected.isUsageLimitReached
            guard confirming || !immediatelyPausesCurrent else {
                data = latest
                persistedData = latest
                persistedModificationDate = Self.modificationDate(for: url)
                stickyAliasRuntime = latest.stickyAlias
                stickyUsageLimitOverrideRuntime = latest.stickyUsageLimitOverride && latest.stickyAlias != nil
                result = .confirmationRequired(projected)
                return
            }

            latest.accounts[index] = projected
            if latest.stickyAlias == alias,
               !latest.stickyUsageLimitOverride,
               projected.isUsageLimitReached {
                latest.stickyAlias = nil
                latest.stickyUsageLimitOverride = false
            }
            guard let raw = try? JSONEncoder.codex.encode(latest) else {
                result = .persistenceFailed
                return
            }
            do {
                try persistAtomically(raw)
            } catch {
                result = .persistenceFailed
                return
            }
            data = latest
            persistedData = latest
            persistedModificationDate = Self.modificationDate(for: url)
            stickyAliasRuntime = latest.stickyAlias
            stickyUsageLimitOverrideRuntime = latest.stickyUsageLimitOverride && latest.stickyAlias != nil
            result = .updated(projected)
        }
        return didLock ? result : .persistenceFailed
    }

    /// Toggles the menu hold. A held account remains selected while it is
    /// hard-eligible, regardless of displayed usage or in-flight leases. The
    /// selected alias is persisted so a separate agent process can hand the
    /// preference to the live app.
    @discardableResult
    public func toggleStickyAlias(_ alias: String, now: Date = Date()) -> Bool {
        refreshExternalStateIfNeeded()
        if stickyAliasRuntime == alias {
            stickyAliasRuntime = nil
            stickyUsageLimitOverrideRuntime = false
            data.stickyAlias = nil
            data.stickyUsageLimitOverride = false
            persist(preservingStickyAlias: false)
            return true
        }
        guard let selected = account(alias), selected.isEligible(now: now, ignoringUsageLimit: true) else { return false }
        stickyAliasRuntime = alias
        stickyUsageLimitOverrideRuntime = selected.isUsageLimitReached
        data.stickyAlias = alias
        data.stickyUsageLimitOverride = stickyUsageLimitOverrideRuntime
        activate(alias, now: now, preservingStickyAlias: false)
        return true
    }

    @discardableResult
    private func clearStickyIfNeeded(_ alias: String) -> Bool {
        if stickyAliasRuntime == alias {
            stickyAliasRuntime = nil
            stickyUsageLimitOverrideRuntime = false
            data.stickyAlias = nil
            data.stickyUsageLimitOverride = false
            return true
        }
        if data.stickyAlias == alias {
            data.stickyAlias = nil
            data.stickyUsageLimitOverride = false
            stickyUsageLimitOverrideRuntime = false
            return true
        }
        return false
    }

    @discardableResult
    private func clearRuntimeHolds(_ alias: String) -> Bool {
        let stickyCleared = clearStickyIfNeeded(alias)
        if drainingHoldAlias == alias { drainingHoldAlias = nil }
        // A semantic provider invalidation supersedes a prior smart-switch
        // observation. Leaving the alias in this runtime set would make it the
        // first candidate again after its cooldown expires.
        drainingAliases.remove(alias)
        drainingObservedAt.removeValue(forKey: alias)
        lunaRejectedUntil.removeValue(forKey: alias)
        return stickyCleared
    }

    public func reserveLunaOpportunity(excluding alias: String? = nil, now: Date = Date()) -> Account? {
        refreshExternalStateIfNeeded()
        lunaRejectedUntil = lunaRejectedUntil.filter { $0.value > now }
        let candidates = data.accounts.filter { account in
            account.alias != alias && account.isRoutableIgnoringCooldown
                && !account.isUsageLimitReached
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
        refreshExternalStateIfNeeded()
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
        persist(preservingRanking: false, preservingStickyAlias: false, clearingActiveAliases: Set(dueAliases))
        return archived
    }

    /// Accounts in the operational roster, in their dense visible rank order.
    /// Routing-paused accounts remain active until they are explicitly archived.
    public func activeAccounts() -> [Account] {
        refreshExternalStateIfNeeded()
        return rankedAccounts(data.accounts.filter { !$0.isArchived })
    }

    /// Accounts retained for history and ownership, excluded from all active
    /// routing and quota consumers.
    public func archivedAccounts() -> [Account] {
        refreshExternalStateIfNeeded()
        return data.accounts
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
        refreshExternalStateIfNeeded()
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
        refreshExternalStateIfNeeded()
        if let stickyAliasRuntime {
            if let sticky = account(stickyAliasRuntime),
               sticky.isEligible(now: now, ignoringUsageLimit: stickyUsageLimitOverrideRuntime) {
                if data.activeAlias != sticky.alias { activate(sticky.alias, now: now) }
                return sticky
            } else {
                self.stickyAliasRuntime = nil
                self.stickyUsageLimitOverrideRuntime = false
                data.stickyAlias = nil
                data.stickyUsageLimitOverride = false
                // Clearing an invalid sticky is an explicit control-plane
                // mutation. Do not merge a stale value from another process
                // back into the file while persisting the clear.
                persist(preservingStickyAlias: false)
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

    private func activate(_ alias: String, now: Date, preservingStickyAlias: Bool = true) {
        refreshExternalStateIfNeeded()
        data.activeAlias = alias
        if let i = index(alias) { data.accounts[i].lastUsedAt = now }
        persist(preservingActiveAlias: false, preservingStickyAlias: preservingStickyAlias)
    }

    public func touchLastUsed(_ alias: String, now: Date = Date()) {
        refreshExternalStateIfNeeded()
        guard let i = index(alias) else { return }
        data.accounts[i].lastUsedAt = now
        persist()
    }

    /// Round-robin load balancing: at a new turn, move to the next least-recently-used eligible
    /// account so usage spreads evenly across all of them. Stays put if nothing else is eligible.
    @discardableResult
    public func advanceRoundRobin(now: Date = Date()) -> Account? {
        refreshExternalStateIfNeeded()
        if let next = eligibleOrdered(now: now, excluding: data.activeAlias).first {
            activate(next.alias, now: now)
            return account(next.alias)
        }
        if let active = data.activeAlias, let acc = account(active), acc.isEligible(now: now) { return acc }
        return current(now: now)
    }

    /// Disable `alias` for `limit` until `resetAt`, then pick the next eligible account.
    public func rotateFrom(_ alias: String, limit: String, resetAt: Date?, now: Date = Date(), fallbackCooldown: TimeInterval) -> RotationResult {
        refreshExternalStateIfNeeded()
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
        guard let picked = next else {
            persist(preservingStickyAlias: false)
            return RotationResult(next: nil, rotated: false)
        }
        activate(picked.alias, now: now, preservingStickyAlias: false)
        return RotationResult(next: account(picked.alias), rotated: true)
    }

    public func markLimited(_ alias: String, limit: String, resetAt: Date?, now: Date = Date(), fallbackCooldown: TimeInterval) {
        guard let i = index(alias) else { return }
        clearRuntimeHolds(alias)
        data.accounts[i].disabledUntil[limit] = resetAt ?? now.addingTimeInterval(fallbackCooldown)
        persist(preservingStickyAlias: false)
    }

    public func markNeedsLoginOnly(_ alias: String) {
        guard let i = index(alias) else { return }
        clearRuntimeHolds(alias)
        data.accounts[i].needsLogin = true
        drainingAliases.remove(alias)
        drainingObservedAt.removeValue(forKey: alias)
        persist(preservingStickyAlias: false)
    }

    public func markNeedsLogin(_ alias: String, now: Date = Date()) -> RotationResult {
        refreshExternalStateIfNeeded()
        clearRuntimeHolds(alias)
        if let i = index(alias) { data.accounts[i].needsLogin = true }
        drainingAliases.remove(alias)
        drainingObservedAt.removeValue(forKey: alias)
        let next: Account?
        switch strategy {
        case .priority: next = eligibleSorted(now: now).first { $0.alias != alias }
        case .roundRobin: next = eligibleOrdered(now: now, excluding: alias).first
        }
        guard let picked = next else {
            persist(preservingStickyAlias: false)
            return RotationResult(next: nil, rotated: false)
        }
        activate(picked.alias, now: now, preservingStickyAlias: false)
        return RotationResult(next: account(picked.alias), rotated: true)
    }

    /// Manual switch: clears the target's cooldowns and needs-login, then activates it.
    @discardableResult
    public func setActive(_ alias: String, now: Date = Date()) -> Account? {
        refreshExternalStateIfNeeded()
        guard let i = index(alias),
              data.accounts[i].routingEnabled,
              !data.accounts[i].isUsageLimitReached,
              !data.accounts[i].isArchived else { return nil }
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
        refreshExternalStateIfNeeded()
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
        let stickyCleared = clearRuntimeHolds(alias)
        if drainingAliases.remove(alias) != nil { changed = true }
        if drainingObservedAt.removeValue(forKey: alias) != nil { changed = true }
        if changed || stickyCleared {
            renumberRanks()
            persist(preservingRanking: false, preservingStickyAlias: false, clearingActiveAliases: [alias])
        }
        return data.accounts[i]
    }

    /// Restore an archived account to the bottom of the active ranking. It remains paused
    /// until the owner explicitly enables routing. Repeating restore is a no-op.
    @discardableResult
    public func restore(alias: String, now: Date? = nil) -> Account? {
        refreshExternalStateIfNeeded()
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
        refreshExternalStateIfNeeded()
        guard let i = index(alias) else { return nil }
        guard let home = data.accounts[i].managedHomePath,
              let tokens = CodexBarBridge.readTokens(home: home) else { return data.accounts[i] }
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
        let previouslyCapped = data.accounts[i].isUsageLimitReached
        let mergedWindows = Self.mergeUsageWindows(previous: previousWindows, current: windows)
        let resetLabels = Self.usageResetOrDecreaseLabels(previous: previousWindows, current: mergedWindows)
        if !resetLabels.isEmpty {
            drainingAliases.remove(alias)
            drainingObservedAt.removeValue(forKey: alias)
            data.accounts[i].usageHistory = (data.accounts[i].usageHistory ?? []).filter {
                !resetLabels.contains($0.label)
            }
        }
        data.accounts[i].usage = mergedWindows
        appendHistorySamples(at: i, windows: windows)
        let nowCapped = data.accounts[i].isUsageLimitReached
        var stickyCleared = false
        if !previouslyCapped,
           nowCapped,
           stickyAliasRuntime == alias,
           !stickyUsageLimitOverrideRuntime {
            stickyCleared = clearStickyIfNeeded(alias)
        }
        // Fresh usage reporting headroom supersedes a recorded cooldown: a limit hit before
        // an early reset (or lifted upstream) must not park the account until the stale
        // resets_at. A limit that still holds re-establishes its cooldown on the next 429.
        if !windows.isEmpty, windows.allSatisfy({ $0.usedPercent < 100 }),
           !data.accounts[i].disabledUntil.isEmpty {
            data.accounts[i].disabledUntil = [:]
        }
        persist(preservingStickyAlias: !stickyCleared)
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

    private static func mergeUsageWindows(previous: [UsageWindow], current: [UsageWindow]) -> [UsageWindow] {
        guard !current.isEmpty else { return previous }
        let currentKeys = Set(current.map(usageWindowIdentity))
        let retained = previous.filter { !currentKeys.contains(usageWindowIdentity($0)) }
        return current + retained
    }

    private static func usageWindowIdentity(_ window: UsageWindow) -> String {
        let normalized = window.label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if window.windowSeconds == 18_000 || normalized == "5h" || normalized == "5-hour" || normalized == "5 hour" {
            return "5h"
        }
        if window.windowSeconds == 604_800 || normalized == "weekly" || normalized == "7d" || normalized == "7-day" || normalized == "7 day" {
            return "weekly"
        }
        return window.windowSeconds > 0 ? "seconds:\(window.windowSeconds)" : "label:\(normalized)"
    }

    /// Applies a complete ranking (top first) to the active roster. Archived accounts
    /// are intentionally outside this visible rank sequence.
    public func applyRanking(_ orderedAliases: [String]) {
        refreshExternalStateIfNeeded()
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
        refreshExternalStateIfNeeded()
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
        refreshExternalStateIfNeeded()
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
        persist(preservingRanking: false, preservingStickyAlias: false, clearingActiveAliases: [alias])
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
        refreshExternalStateIfNeeded()
        let removedAccounts = data.accounts.filter {
            $0.managedHomePath != nil && !present.contains($0.accountID)
        }
        guard !removedAccounts.isEmpty else { return AccountRemovalResult() }
        let removed = Set(removedAccounts.map(\.alias))
        data.accounts.removeAll { removed.contains($0.alias) }
        if let active = data.activeAlias, removed.contains(active) { data.activeAlias = nil }
        let removedStickyAlias = (stickyAliasRuntime.map { removed.contains($0) } ?? false)
            || (data.stickyAlias.map { removed.contains($0) } ?? false)
        if removedStickyAlias {
            self.stickyAliasRuntime = nil
            self.stickyUsageLimitOverrideRuntime = false
            data.stickyAlias = nil
            data.stickyUsageLimitOverride = false
        }
        if let drainingHoldAlias, removed.contains(drainingHoldAlias) { self.drainingHoldAlias = nil }
        for alias in removed { lunaRejectedUntil.removeValue(forKey: alias) }
        drainingAliases.subtract(removed)
        for alias in removed { drainingObservedAt.removeValue(forKey: alias) }
        renumberRanks()
        persist(preservingRanking: false, preservingStickyAlias: false, clearingActiveAliases: removed)
        return AccountRemovalResult(
            removedAliases: removedAccounts.map(\.alias),
            removedTelemetryIDs: removedAccounts.map(\.telemetryID)
        )
    }

    /// Insert or update an account keyed by accountID (falling back to alias). Preserves priority on update.
    @discardableResult
    public func upsert(_ account: Account) -> Account {
        refreshExternalStateIfNeeded()
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
            // Usage limits are user-owned control-plane state. CodexBar/import
            // snapshots do not carry this field and must never reset a cap.
            merged.usageLimitSettings = data.accounts[i].usageLimitSettings
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
        refreshExternalStateIfNeeded()
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
        // Disabling an account also clears a local active selection. Keep that
        // intent when it does not conflict with a newer active-alias change;
        // enabling leaves the latest active selection untouched.
        persist(preservingActiveAlias: enabled, preservingStickyAlias: enabled)
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
