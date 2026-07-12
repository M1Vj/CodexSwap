import Foundation

public struct Settings: Codable, Sendable, Equatable {
    public var rotationStrategy: RotationStrategy
    /// Pre-emptively rotate away from the active account when its primary (5h) window reaches this percent.
    public var primaryThresholdPercent: Int
    /// Pre-emptively rotate when the secondary (weekly) window reaches this percent.
    public var secondaryThresholdPercent: Int
    /// Seconds between usage polls of the active account (conservative default matches Codex's own TUI).
    public var usagePollSeconds: Int
    /// Fallback cooldown when a 429 gives no reset timestamp.
    public var defaultCooldownSeconds: Int
    /// Round-robin: a model call arriving more than this many seconds after the previous one starts a
    /// new turn and rotates to the next account. Keeps a single turn (and its tool loop) on one account.
    public var roundRobinTurnGapSeconds: Int
    public var notifyOnRotate: Bool
    public var notifyOnExhausted: Bool
    public var notifyOnWindowReset: Bool
    public var launchAtLogin: Bool
    public var routeCodexAutomatically: Bool
    public var automaticallyWarmAccounts: Bool
    public var proxyPort: Int

    public static let defaultProxyPort = 58_432

    public static let `default` = Settings(
        rotationStrategy: .priority,
        primaryThresholdPercent: 95,
        secondaryThresholdPercent: 98,
        usagePollSeconds: 60,
        defaultCooldownSeconds: 18000,
        roundRobinTurnGapSeconds: 6,
        notifyOnRotate: true,
        notifyOnExhausted: true,
        notifyOnWindowReset: true,
        launchAtLogin: false,
        routeCodexAutomatically: false,
        automaticallyWarmAccounts: false,
        proxyPort: defaultProxyPort
    )

    public init(
        rotationStrategy: RotationStrategy,
        primaryThresholdPercent: Int,
        secondaryThresholdPercent: Int,
        usagePollSeconds: Int,
        defaultCooldownSeconds: Int,
        roundRobinTurnGapSeconds: Int,
        notifyOnRotate: Bool,
        notifyOnExhausted: Bool,
        notifyOnWindowReset: Bool,
        launchAtLogin: Bool,
        routeCodexAutomatically: Bool,
        automaticallyWarmAccounts: Bool,
        proxyPort: Int
    ) {
        self.rotationStrategy = rotationStrategy
        self.primaryThresholdPercent = primaryThresholdPercent
        self.secondaryThresholdPercent = secondaryThresholdPercent
        self.usagePollSeconds = usagePollSeconds
        self.defaultCooldownSeconds = defaultCooldownSeconds
        self.roundRobinTurnGapSeconds = roundRobinTurnGapSeconds
        self.notifyOnRotate = notifyOnRotate
        self.notifyOnExhausted = notifyOnExhausted
        self.notifyOnWindowReset = notifyOnWindowReset
        self.launchAtLogin = launchAtLogin
        self.routeCodexAutomatically = routeCodexAutomatically
        self.automaticallyWarmAccounts = automaticallyWarmAccounts
        self.proxyPort = proxyPort
    }

    /// Tolerant decoder: missing keys fall back to defaults so new fields never invalidate an old file.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings.default
        rotationStrategy = try c.decodeIfPresent(RotationStrategy.self, forKey: .rotationStrategy) ?? d.rotationStrategy
        primaryThresholdPercent = try c.decodeIfPresent(Int.self, forKey: .primaryThresholdPercent) ?? d.primaryThresholdPercent
        secondaryThresholdPercent = try c.decodeIfPresent(Int.self, forKey: .secondaryThresholdPercent) ?? d.secondaryThresholdPercent
        usagePollSeconds = try c.decodeIfPresent(Int.self, forKey: .usagePollSeconds) ?? d.usagePollSeconds
        defaultCooldownSeconds = try c.decodeIfPresent(Int.self, forKey: .defaultCooldownSeconds) ?? d.defaultCooldownSeconds
        roundRobinTurnGapSeconds = try c.decodeIfPresent(Int.self, forKey: .roundRobinTurnGapSeconds) ?? d.roundRobinTurnGapSeconds
        notifyOnRotate = try c.decodeIfPresent(Bool.self, forKey: .notifyOnRotate) ?? d.notifyOnRotate
        notifyOnExhausted = try c.decodeIfPresent(Bool.self, forKey: .notifyOnExhausted) ?? d.notifyOnExhausted
        notifyOnWindowReset = try c.decodeIfPresent(Bool.self, forKey: .notifyOnWindowReset) ?? d.notifyOnWindowReset
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? d.launchAtLogin
        routeCodexAutomatically = try c.decodeIfPresent(Bool.self, forKey: .routeCodexAutomatically) ?? d.routeCodexAutomatically
        automaticallyWarmAccounts = try c.decodeIfPresent(Bool.self, forKey: .automaticallyWarmAccounts) ?? d.automaticallyWarmAccounts
        let decodedPort = try c.decodeIfPresent(Int.self, forKey: .proxyPort) ?? d.proxyPort
        proxyPort = (1...65_535).contains(decodedPort) ? decodedPort : d.proxyPort
    }
}

public enum AppPaths {
    public static func supportDir() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("CodexSwap", isDirectory: true)
    }
    public static func storeFile() -> URL { supportDir().appendingPathComponent("accounts.json") }
    public static func settingsFile() -> URL { supportDir().appendingPathComponent("settings.json") }
    public static func historyFile() -> URL { supportDir().appendingPathComponent("history.jsonl") }
    public static func warmupFile() -> URL { supportDir().appendingPathComponent("warmup.json") }
}
