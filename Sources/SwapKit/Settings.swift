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
    public var notifyOnRotate: Bool
    public var notifyOnExhausted: Bool
    public var notifyOnWindowReset: Bool
    public var launchAtLogin: Bool

    public static let `default` = Settings(
        rotationStrategy: .priority,
        primaryThresholdPercent: 95,
        secondaryThresholdPercent: 98,
        usagePollSeconds: 60,
        defaultCooldownSeconds: 18000,
        notifyOnRotate: true,
        notifyOnExhausted: true,
        notifyOnWindowReset: true,
        launchAtLogin: false
    )

    public init(
        rotationStrategy: RotationStrategy,
        primaryThresholdPercent: Int,
        secondaryThresholdPercent: Int,
        usagePollSeconds: Int,
        defaultCooldownSeconds: Int,
        notifyOnRotate: Bool,
        notifyOnExhausted: Bool,
        notifyOnWindowReset: Bool,
        launchAtLogin: Bool
    ) {
        self.rotationStrategy = rotationStrategy
        self.primaryThresholdPercent = primaryThresholdPercent
        self.secondaryThresholdPercent = secondaryThresholdPercent
        self.usagePollSeconds = usagePollSeconds
        self.defaultCooldownSeconds = defaultCooldownSeconds
        self.notifyOnRotate = notifyOnRotate
        self.notifyOnExhausted = notifyOnExhausted
        self.notifyOnWindowReset = notifyOnWindowReset
        self.launchAtLogin = launchAtLogin
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
}
