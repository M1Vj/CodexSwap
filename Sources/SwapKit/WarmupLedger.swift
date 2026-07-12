import Foundation

public struct WarmupRecord: Codable, Sendable, Equatable {
    public var succeededAt: Date
    public var primaryResetAt: Date?
    public var secondaryResetAt: Date?
    public var retryAfter: Date?

    public init(succeededAt: Date, primaryResetAt: Date?, secondaryResetAt: Date?, retryAfter: Date? = nil) {
        self.succeededAt = succeededAt
        self.primaryResetAt = primaryResetAt
        self.secondaryResetAt = secondaryResetAt
        self.retryAfter = retryAfter
    }

    public func isDue(at now: Date) -> Bool {
        if let retryAfter, retryAfter > now { return false }
        return (primaryResetAt ?? succeededAt.addingTimeInterval(18_000)) <= now
    }
}

public struct WarmupSummary: Codable, Sendable, Equatable {
    public var startedAt: Date
    public var finishedAt: Date
    public var warmed: [String]
    public var skipped: [String: String]
    public var failed: [String: String]

    public init(startedAt: Date, finishedAt: Date, warmed: [String] = [], skipped: [String: String] = [:], failed: [String: String] = [:]) {
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.warmed = warmed
        self.skipped = skipped
        self.failed = failed
    }

    public var statusText: String {
        "\(warmed.count) warmed · \(skipped.count) skipped · \(failed.count) failed"
    }
}

public actor WarmupLedgerStore {
    private struct Ledger: Codable {
        var records: [String: WarmupRecord] = [:]
        var lastSummary: WarmupSummary?
    }

    private let url: URL
    private var value: Ledger

    public init(url: URL = AppPaths.warmupFile()) {
        self.url = url
        self.value = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder.codex.decode(Ledger.self, from: $0) } ?? Ledger()
    }

    public func record(for key: String) -> WarmupRecord? { value.records[key] }
    public func lastSummary() -> WarmupSummary? { value.lastSummary }

    public func setRecord(_ record: WarmupRecord, for key: String) {
        value.records[key] = record
        persist()
    }

    public func setLastSummary(_ summary: WarmupSummary) {
        value.lastSummary = summary
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder.codex.encode(value) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
