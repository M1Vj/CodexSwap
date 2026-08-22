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
        public var outputTokens: Int
        public var reasoningOutputTokens: Int
        public var lastUsed: Date

        public init(requests: Int = 0, inputTokens: Int = 0, cachedInputTokens: Int = 0, outputTokens: Int = 0, reasoningOutputTokens: Int = 0, lastUsed: Date = .init()) {
            self.requests = requests
            self.inputTokens = inputTokens
            self.cachedInputTokens = cachedInputTokens
            self.outputTokens = outputTokens
            self.reasoningOutputTokens = reasoningOutputTokens
            self.lastUsed = lastUsed
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
        }
        public let todayRows: [Row]
        public let allTimeRows: [Row]
    }

    nonisolated(unsafe) private static var sharedOverride: BridgedUsageStore?
    public static var shared: BridgedUsageStore {
        if let sharedOverride { return sharedOverride }
        return sharedDefault
    }
    nonisolated(unsafe) private static let sharedDefault = BridgedUsageStore()

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
        if let data = try? Data(contentsOf: self.url),
           let state = try? JSONDecoder().decode(PersistedState.self, from: data) {
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
        outputTokens: Int,
        reasoningOutputTokens: Int = 0
    ) {
        guard !modelID.isEmpty else { return }
        let dayKey = Self.dayKey(for: now())
        let stamp = now()
        func bump(_ entry: inout Entry) {
            entry.requests += 1
            entry.inputTokens += inputTokens
            entry.cachedInputTokens += cachedInputTokens
            entry.outputTokens += outputTokens
            entry.reasoningOutputTokens += reasoningOutputTokens
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

    public func snapshot(prices: [String: (input: Double, output: Double)]) -> Snapshot {
        func rows(_ dict: [String: Entry]) -> [Snapshot.Row] {
            dict.map { modelID, entry in
                let price = prices[modelID] ?? (0, 0)
                let billable = max(entry.inputTokens - entry.cachedInputTokens, 0)
                let cost = Double(billable) / 1_000_000 * price.input
                    + Double(entry.outputTokens) / 1_000_000 * price.output
                return Snapshot.Row(modelID: modelID, entry: entry, estimatedCost: cost)
            }
            .sorted { $0.entry.lastUsed > $1.entry.lastUsed }
        }
        return Snapshot(todayRows: rows(byDay[Self.dayKey(for: now())] ?? [:]), allTimeRows: rows(allTime))
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
