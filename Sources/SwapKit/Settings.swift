import Foundation

public enum QuotaExhaustionPolicy: String, Codable, Sendable, CaseIterable {
    case resetCurrentFirst
    case switchFirst
    case stopAndNotify
}

/// A non-Codex model served through the proxy's translation lane
/// (Responses API on the client side, Chat Completions upstream).
public struct BridgedModel: Codable, Sendable, Equatable, Identifiable {
    public var modelID: String
    public var displayName: String
    /// Base URL ending at the version segment, e.g. https://opencode.ai/zen/v1
    public var baseURL: String
    /// Optional bearer credential; empty means anonymous (typical for free tiers).
    public var apiKey: String
    public var enabled: Bool
    /// Optional pricing in currency units per million input tokens (nil/0 = free tier).
    public var inputPricePerMillion: Double?
    /// Optional pricing in currency units per million output tokens.
    public var outputPricePerMillion: Double?

    public init(
        modelID: String,
        displayName: String = "",
        baseURL: String,
        apiKey: String = "",
        enabled: Bool = true,
        inputPricePerMillion: Double? = nil,
        outputPricePerMillion: Double? = nil
    ) {
        self.modelID = modelID
        self.displayName = displayName.isEmpty ? modelID : displayName
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.enabled = enabled
        self.inputPricePerMillion = inputPricePerMillion
        self.outputPricePerMillion = outputPricePerMillion
    }

    public var id: String { modelID }
}

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
    public var warmupExcludedAccounts: [String]
    public var automaticallyResetExhaustedAccounts: Bool
    public var interactiveExhaustionPolicy: QuotaExhaustionPolicy
    public var taskBoardExhaustionPolicy: QuotaExhaustionPolicy
    public var autoResetProtectedAccounts: [String]
    public var automationEnabled: Bool
    public var automationAccounts: [String]
    public var automationMaxConcurrent: Int
    public var automationConsumeBankedWindow: Bool
    /// Minimum unused percent every reported window must retain for a run START to be admitted;
    /// mid-run proxy failover is not gated by this.
    public var automationMinHeadroomPercent: Int
    public var automationDefaultModel: String
    public var notifyOnTaskEvents: Bool
    /// Post a notification when an account is flagged as needing sign-in (deduplicated per episode).
    public var notifyOnNeedsLogin: Bool
    /// Prefer accounts whose quota is draining from other users' activity when picking the next account.
    public var smartSwitchEnabled: Bool
    public var proxyPort: Int
    /// Free/gateway models served through the Responses<->Chat bridge instead of Codex accounts.
    public var bridgedModels: [BridgedModel]
    public var subagentModelPolicy: SubagentModelPolicy

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
        warmupExcludedAccounts: [],
        automaticallyResetExhaustedAccounts: false,
        interactiveExhaustionPolicy: .resetCurrentFirst,
        taskBoardExhaustionPolicy: .stopAndNotify,
        autoResetProtectedAccounts: [],
        automationEnabled: false,
        automationAccounts: [],
        automationMaxConcurrent: 1,
        automationConsumeBankedWindow: false,
        automationMinHeadroomPercent: 5,
        automationDefaultModel: "gpt-5.6-sol",
        notifyOnTaskEvents: true,
        notifyOnNeedsLogin: true,
        smartSwitchEnabled: false,
        proxyPort: defaultProxyPort,
        bridgedModels: [
            BridgedModel(
                modelID: "x-preview-f-free",
                displayName: "Ox Alpha Free",
                baseURL: "https://opencode.ai/zen/v1"
            )
        ]
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
        warmupExcludedAccounts: [String],
        automaticallyResetExhaustedAccounts: Bool = false,
        interactiveExhaustionPolicy: QuotaExhaustionPolicy = .resetCurrentFirst,
        taskBoardExhaustionPolicy: QuotaExhaustionPolicy = .stopAndNotify,
        autoResetProtectedAccounts: [String] = [],
        automationEnabled: Bool,
        automationAccounts: [String],
        automationMaxConcurrent: Int,
        automationConsumeBankedWindow: Bool,
        automationMinHeadroomPercent: Int = 5,
        automationDefaultModel: String,
        notifyOnTaskEvents: Bool,
        notifyOnNeedsLogin: Bool = true,
        smartSwitchEnabled: Bool = false,
        proxyPort: Int,
        bridgedModels: [BridgedModel]? = nil,
        subagentModelPolicy: SubagentModelPolicy = .default
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
        self.warmupExcludedAccounts = warmupExcludedAccounts
        self.automaticallyResetExhaustedAccounts = automaticallyResetExhaustedAccounts
        self.interactiveExhaustionPolicy = interactiveExhaustionPolicy
        self.taskBoardExhaustionPolicy = taskBoardExhaustionPolicy
        self.autoResetProtectedAccounts = autoResetProtectedAccounts
        self.automationEnabled = automationEnabled
        self.automationAccounts = automationAccounts
        self.automationMaxConcurrent = automationMaxConcurrent
        self.automationConsumeBankedWindow = automationConsumeBankedWindow
        self.automationMinHeadroomPercent = min(max(automationMinHeadroomPercent, 0), 50)
        self.automationDefaultModel = automationDefaultModel
        self.notifyOnTaskEvents = notifyOnTaskEvents
        self.notifyOnNeedsLogin = notifyOnNeedsLogin
        self.smartSwitchEnabled = smartSwitchEnabled
        self.proxyPort = proxyPort
        self.bridgedModels = bridgedModels ?? Settings.default.bridgedModels
        self.subagentModelPolicy = subagentModelPolicy
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
        warmupExcludedAccounts = try c.decodeIfPresent([String].self, forKey: .warmupExcludedAccounts) ?? d.warmupExcludedAccounts
        automaticallyResetExhaustedAccounts = try c.decodeIfPresent(Bool.self, forKey: .automaticallyResetExhaustedAccounts) ?? d.automaticallyResetExhaustedAccounts
        let interactivePolicyRaw = try c.decodeIfPresent(String.self, forKey: .interactiveExhaustionPolicy)
        interactiveExhaustionPolicy = interactivePolicyRaw.flatMap(QuotaExhaustionPolicy.init(rawValue:)) ?? d.interactiveExhaustionPolicy
        let taskBoardPolicyRaw = try c.decodeIfPresent(String.self, forKey: .taskBoardExhaustionPolicy)
        taskBoardExhaustionPolicy = taskBoardPolicyRaw.flatMap(QuotaExhaustionPolicy.init(rawValue:)) ?? d.taskBoardExhaustionPolicy
        autoResetProtectedAccounts = try c.decodeIfPresent([String].self, forKey: .autoResetProtectedAccounts) ?? d.autoResetProtectedAccounts
        automationEnabled = try c.decodeIfPresent(Bool.self, forKey: .automationEnabled) ?? d.automationEnabled
        automationAccounts = try c.decodeIfPresent([String].self, forKey: .automationAccounts) ?? d.automationAccounts
        let decodedMaxConcurrent = try c.decodeIfPresent(Int.self, forKey: .automationMaxConcurrent) ?? d.automationMaxConcurrent
        automationMaxConcurrent = (1...4).contains(decodedMaxConcurrent) ? decodedMaxConcurrent : d.automationMaxConcurrent
        automationConsumeBankedWindow = try c.decodeIfPresent(Bool.self, forKey: .automationConsumeBankedWindow) ?? d.automationConsumeBankedWindow
        let decodedHeadroom = try c.decodeIfPresent(Int.self, forKey: .automationMinHeadroomPercent) ?? d.automationMinHeadroomPercent
        automationMinHeadroomPercent = (0...50).contains(decodedHeadroom) ? decodedHeadroom : d.automationMinHeadroomPercent
        automationDefaultModel = try c.decodeIfPresent(String.self, forKey: .automationDefaultModel) ?? d.automationDefaultModel
        notifyOnTaskEvents = try c.decodeIfPresent(Bool.self, forKey: .notifyOnTaskEvents) ?? d.notifyOnTaskEvents
        notifyOnNeedsLogin = try c.decodeIfPresent(Bool.self, forKey: .notifyOnNeedsLogin) ?? d.notifyOnNeedsLogin
        smartSwitchEnabled = try c.decodeIfPresent(Bool.self, forKey: .smartSwitchEnabled) ?? d.smartSwitchEnabled
        let decodedPort = try c.decodeIfPresent(Int.self, forKey: .proxyPort) ?? d.proxyPort
        proxyPort = (1...65_535).contains(decodedPort) ? decodedPort : d.proxyPort
        let decodedBridged = try c.decodeIfPresent([BridgedModel].self, forKey: .bridgedModels) ?? d.bridgedModels
        bridgedModels = decodedBridged.filter { !$0.modelID.isEmpty && URL(string: $0.baseURL) != nil }
        do {
            subagentModelPolicy = try c.decodeIfPresent(SubagentModelPolicy.self, forKey: .subagentModelPolicy)
                ?? d.subagentModelPolicy
        } catch {
            subagentModelPolicy = d.subagentModelPolicy
        }
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
