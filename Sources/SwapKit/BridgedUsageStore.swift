import Foundation

/// Aggregated token usage for bridged (non-Codex) models. These models consume
/// no Codex account quota, so their usage lives in its own store rather than in
/// per-account stats. Persists atomically; pricing fields on `BridgedModel`
/// (per million tokens) turn raw counts into estimated cost whenever a gateway
/// starts charging for a model that launched free.
public actor BridgedUsageStore {
    public struct Entry: Codable, Sendable, Equatable {
        public var requests: Int
        public var inputTokens: Int
        public var cachedInputTokens: Int
        public var cacheWriteInputTokens: Int
        public var cachedInputCompleteness: TokenFieldCompleteness
        public var cacheWriteInputCompleteness: TokenFieldCompleteness
        public var outputTokens: Int
        public var reasoningOutputTokens: Int
        public var lastUsed: Date

        public init(
            requests: Int = 0,
            inputTokens: Int = 0,
            cachedInputTokens: Int = 0,
            cacheWriteInputTokens: Int = 0,
            outputTokens: Int = 0,
            reasoningOutputTokens: Int = 0,
            lastUsed: Date = .init(),
            cachedInputCompleteness: TokenFieldCompleteness? = nil,
            cacheWriteInputCompleteness: TokenFieldCompleteness? = nil
        ) {
            self.requests = requests
            self.inputTokens = inputTokens
            self.cachedInputTokens = cachedInputTokens
            self.cacheWriteInputTokens = cacheWriteInputTokens
            self.cachedInputCompleteness = cachedInputCompleteness
                ?? (requests > 0 ? .complete : .unknown)
            self.cacheWriteInputCompleteness = cacheWriteInputCompleteness
                ?? (requests > 0 ? .complete : .unknown)
            self.outputTokens = outputTokens
            self.reasoningOutputTokens = reasoningOutputTokens
            self.lastUsed = lastUsed
        }

        private enum CodingKeys: String, CodingKey {
            case requests, inputTokens, cachedInputTokens, cacheWriteInputTokens
            case cachedInputCompleteness, cacheWriteInputCompleteness
            case outputTokens, reasoningOutputTokens, lastUsed
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            requests = try c.decodeIfPresent(Int.self, forKey: .requests) ?? 0
            inputTokens = try c.decodeIfPresent(Int.self, forKey: .inputTokens) ?? 0
            cachedInputTokens = try c.decodeIfPresent(Int.self, forKey: .cachedInputTokens) ?? 0
            cacheWriteInputTokens = try c.decodeIfPresent(Int.self, forKey: .cacheWriteInputTokens) ?? 0
            cachedInputCompleteness = try c.decodeIfPresent(TokenFieldCompleteness.self, forKey: .cachedInputCompleteness) ?? .unknown
            cacheWriteInputCompleteness = try c.decodeIfPresent(TokenFieldCompleteness.self, forKey: .cacheWriteInputCompleteness) ?? .unknown
            outputTokens = try c.decodeIfPresent(Int.self, forKey: .outputTokens) ?? 0
            reasoningOutputTokens = try c.decodeIfPresent(Int.self, forKey: .reasoningOutputTokens) ?? 0
            if let rawDate = try? c.decode(String.self, forKey: .lastUsed) {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                if let date = formatter.date(from: rawDate) {
                    lastUsed = date
                } else {
                    formatter.formatOptions = [.withInternetDateTime]
                    lastUsed = formatter.date(from: rawDate) ?? Date()
                }
            } else if let seconds = try? c.decode(Double.self, forKey: .lastUsed), seconds.isFinite {
                // Older JSONEncoder output used Date's numeric seconds-since-epoch strategy.
                lastUsed = Date(timeIntervalSince1970: seconds)
            } else {
                lastUsed = Date()
            }
        }
    }

    /// Optional per-million pricing configured for a bridged model. Nil means the
    /// provider did not publish a rate; a missing cache rate falls back to the
    /// configured uncached input rate rather than silently becoming free.
    public struct Pricing: Sendable, Equatable {
        public var inputPerMillion: Double?
        public var cachedInputPerMillion: Double?
        public var cacheWriteInputPerMillion: Double?
        public var outputPerMillion: Double?

        public init(
            inputPerMillion: Double? = nil,
            cachedInputPerMillion: Double? = nil,
            cacheWriteInputPerMillion: Double? = nil,
            outputPerMillion: Double? = nil
        ) {
            self.inputPerMillion = inputPerMillion
            self.cachedInputPerMillion = cachedInputPerMillion
            self.cacheWriteInputPerMillion = cacheWriteInputPerMillion
            self.outputPerMillion = outputPerMillion
        }

        public var isSpecified: Bool {
            // Input and output are the minimum contract for a useful estimate.
            // Cache rates remain optional and safely fall back to input when absent.
            guard let inputPerMillion, let outputPerMillion,
                  inputPerMillion.isFinite, inputPerMillion >= 0,
                  outputPerMillion.isFinite, outputPerMillion >= 0 else {
                return false
            }
            return [cachedInputPerMillion, cacheWriteInputPerMillion]
                .compactMap { $0 }
                .allSatisfy { $0.isFinite && $0 >= 0 }
        }

        fileprivate var modelPrice: ModelPrice {
            ModelPrice(
                inputPerMillion: inputPerMillion ?? 0,
                cachedInputPerMillion: cachedInputPerMillion,
                outputPerMillion: outputPerMillion ?? 0,
                cacheWriteInputPerMillion: cacheWriteInputPerMillion
            )
        }
    }

    struct PersistedState: Codable, Sendable {
        var allTime: [String: Entry]
        var byDay: [String: [String: Entry]]
    }

    public struct Snapshot: Sendable, Equatable {
        public struct Row: Identifiable, Sendable, Equatable {
            public var id: String { modelID }
            public let modelID: String
            public let entry: Entry
            public let estimatedCost: Double
            public let pricing: Pricing?
            public var cachedInputCompleteness: TokenFieldCompleteness { entry.cachedInputCompleteness }
            public var cacheWriteInputCompleteness: TokenFieldCompleteness { entry.cacheWriteInputCompleteness }

            public var pricingAvailable: Bool { pricing?.isSpecified == true }
        }
        public let todayRows: [Row]
        public let allTimeRows: [Row]
    }

    nonisolated(unsafe) private static var sharedOverride: BridgedUsageStore?
    public static var shared: BridgedUsageStore {
        if let sharedOverride { return sharedOverride }
        return sharedDefault
    }
    private static let sharedDefault = BridgedUsageStore()

    /// Test seam.
    public static func makeShared(url: URL, now: @escaping @Sendable () -> Date = { Date() }) -> BridgedUsageStore {
        let store = BridgedUsageStore(url: url, now: now)
        sharedOverride = store
        return store
    }
    public static func resetShared() { sharedOverride = nil }

    private let url: URL
    private let now: @Sendable () -> Date
    private var allTime: [String: Entry]
    private var byDay: [String: [String: Entry]]

    public init(url: URL? = nil, now: @escaping @Sendable () -> Date = { Date() }) {
        self.url = url ?? AppPaths.supportDir().appendingPathComponent("bridged-usage.json")
        self.now = now
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: self.url),
           let state = try? decoder.decode(PersistedState.self, from: data) {
            allTime = state.allTime
            byDay = state.byDay
        } else {
            allTime = [:]
            byDay = [:]
        }
    }

    public func record(
        modelID: String,
        inputTokens: Int,
        cachedInputTokens: Int,
        cacheWriteInputTokens: Int = 0,
        outputTokens: Int,
        reasoningOutputTokens: Int = 0,
        cachedInputPresence: TokenFieldPresence = .present,
        cacheWriteInputPresence: TokenFieldPresence? = nil
    ) {
        guard !modelID.isEmpty else { return }
        let dayKey = Self.dayKey(for: now())
        let stamp = now()
        let inputTokens = max(0, inputTokens)
        let cachedInputTokens = min(max(0, cachedInputTokens), inputTokens)
        let cacheWriteInputTokens = min(max(0, cacheWriteInputTokens), inputTokens - cachedInputTokens)
        let outputTokens = max(0, outputTokens)
        let reasoningOutputTokens = max(0, reasoningOutputTokens)
        func bump(_ entry: inout Entry) {
            let hadExistingRequest = entry.requests > 0
            entry.requests = UsageSafety.saturatingIncrement(entry.requests)
            entry.inputTokens = UsageSafety.saturatingAdd(entry.inputTokens, inputTokens)
            entry.cachedInputTokens = UsageSafety.saturatingAdd(entry.cachedInputTokens, cachedInputTokens)
            entry.cacheWriteInputTokens = UsageSafety.saturatingAdd(entry.cacheWriteInputTokens, cacheWriteInputTokens)
            entry.cachedInputCompleteness = UsageAnalytics.advanceCompleteness(
                entry.cachedInputCompleteness,
                presence: cachedInputPresence,
                hasExistingRequest: hadExistingRequest
            )
            let writePresence = cacheWriteInputPresence
                ?? (cacheWriteInputTokens > 0 ? .present : .absent)
            entry.cacheWriteInputCompleteness = UsageAnalytics.advanceCompleteness(
                entry.cacheWriteInputCompleteness,
                presence: writePresence,
                hasExistingRequest: hadExistingRequest
            )
            entry.outputTokens = UsageSafety.saturatingAdd(entry.outputTokens, outputTokens)
            entry.reasoningOutputTokens = UsageSafety.saturatingAdd(entry.reasoningOutputTokens, reasoningOutputTokens)
            entry.lastUsed = stamp
        }
        if allTime[modelID] == nil { allTime[modelID] = Entry() }
        bump(&allTime[modelID]!)
        var dayEntries = byDay[dayKey, default: [:]]
        if dayEntries[modelID] == nil { dayEntries[modelID] = Entry() }
        bump(&dayEntries[modelID]!)
        byDay[dayKey] = dayEntries
        persist()
    }

    public func snapshot(prices: [String: Pricing]) -> Snapshot {
        func rows(_ dict: [String: Entry]) -> [Snapshot.Row] {
            dict.map { modelID, entry in
                let pricing = prices[modelID]
                let cost = pricing.flatMap { pricing -> Double? in
                    guard pricing.isSpecified else { return nil }
                    return UsageAnalytics.estimatedCost(
                        inputTokens: entry.inputTokens,
                        cachedInputTokens: entry.cachedInputCompleteness == .unknown ? nil : entry.cachedInputTokens,
                        cacheWriteInputTokens: entry.cacheWriteInputCompleteness == .unknown ? nil : entry.cacheWriteInputTokens,
                        outputTokens: entry.outputTokens,
                        price: pricing.modelPrice
                    )
                } ?? 0
                return Snapshot.Row(modelID: modelID, entry: entry, estimatedCost: cost, pricing: pricing)
            }
            .sorted { $0.entry.lastUsed > $1.entry.lastUsed }
        }
        return Snapshot(todayRows: rows(byDay[Self.dayKey(for: now())] ?? [:]), allTimeRows: rows(allTime))
    }

    /// Compatibility overload for callers that only know input/output rates.
    public func snapshot(prices: [String: (input: Double, output: Double)]) -> Snapshot {
        let converted = prices.mapValues {
            Pricing(inputPerMillion: $0.input, outputPerMillion: $0.output)
        }
        return snapshot(prices: converted)
    }

    public func reset() {
        allTime = [:]
        byDay = [:]
        persist()
    }

    private func persist() {
        let state = PersistedState(allTime: allTime, byDay: byDay)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(state) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? data.write(to: url, options: .atomic)
    }

    nonisolated static func dayKey(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current
        return formatter.string(from: date)
    }
}
