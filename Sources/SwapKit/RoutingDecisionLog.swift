import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Closed set of routing events persisted by `RoutingDecisionLog`.
///
/// Keep this list intentionally small. Routing logs are for reconstructing
/// account-selection decisions, not for retaining request or provider data.
public enum RoutingDecisionLogEvent: String, Codable, Sendable, CaseIterable {
    case requestStarted = "request_started"
    case requestTerminal = "request_terminal"
    case genericRetryCurrent = "generic_retry_current"
    case genericExhausted = "generic_exhausted"
    case semanticLimit = "semantic_limit"
    case switchReplay = "switch_replay"
    case noTargetStop = "no_target_stop"
}

/// The only distinction retained for an upstream 429.
public enum RoutingDecisionLogRateLimitKind: String, Codable, Sendable, CaseIterable {
    case semantic
    case generic
}

/// Bounded routing outcomes. The raw strings are part of the local JSONL schema.
public enum RoutingDecisionLogRoutingDecision: String, Codable, Sendable, CaseIterable {
    case retryCurrent = "retry_current"
    case switchToAlternative = "switch_to_alternative"
    case stop
    case success
    case failure
}

/// Bounded reasons for a routing event. Never construct this enum from provider
/// text, request content, aliases, or other untrusted strings.
public enum RoutingDecisionLogReason: String, Codable, Sendable, CaseIterable {
    case requestStart = "request_start"
    case genericRetryAfter = "generic_retry_after"
    case generic429Exhausted = "generic_429_exhausted"
    case semanticLimit = "semantic_limit"
    case switchReplay = "switch_replay"
    case noEligibleTarget = "no_eligible_target"
    case noAlternative = "no_alternative"
    case policyStop = "policy_stop"
    case terminalSuccess = "terminal_success"
    case terminalFailure = "terminal_failure"
}

/// One privacy-safe routing decision record. This is a closed allowlist: adding
/// fields requires an explicit schema review because the log is durable local
/// state and may be inspected after an incident.
public struct RoutingDecisionLogRecord: Codable, Sendable, Equatable {
    public static let schemaVersion = 1
    public static let maximumActiveBytes = 1_048_576
    public static let maximumRetryAfterSeconds: Double = 30
    public static let maximumAttempt = 64

    public let schemaVersion: Int
    /// RFC 3339/ISO-8601 UTC timestamp with fractional seconds.
    public let timestamp: String
    public let event: RoutingDecisionLogEvent
    public let rootRequestID: UUID
    public let attempt: Int?
    public let attemptCount: Int?
    /// Only valid HTTP status codes are retained; all other values are omitted.
    public let status: Int?
    public let rateLimitKind: RoutingDecisionLogRateLimitKind?
    public let retryAfterPresent: Bool?
    /// Provider delay, when present, is clamped to 0...30 seconds.
    public let retryAfterSeconds: Double?
    public let routingDecision: RoutingDecisionLogRoutingDecision?
    public let reason: RoutingDecisionLogReason?
    /// Random account telemetry IDs are opaque and may be retained for local
    /// correlation. Aliases, account IDs, emails, and tokens are not accepted.
    public let accountTelemetryID: UUID?
    public let targetAccountTelemetryID: UUID?

    public init(
        event: RoutingDecisionLogEvent,
        rootRequestID: UUID,
        timestamp: Date = Date(),
        attempt: Int? = nil,
        attemptCount: Int? = nil,
        status: Int? = nil,
        rateLimitKind: RoutingDecisionLogRateLimitKind? = nil,
        retryAfterPresent: Bool? = nil,
        retryAfterSeconds: Double? = nil,
        routingDecision: RoutingDecisionLogRoutingDecision? = nil,
        reason: RoutingDecisionLogReason? = nil,
        accountTelemetryID: UUID? = nil,
        targetAccountTelemetryID: UUID? = nil
    ) {
        self.schemaVersion = Self.schemaVersion
        self.timestamp = Self.utcString(timestamp)
        self.event = event
        self.rootRequestID = rootRequestID
        self.attempt = Self.boundAttempt(attempt)
        self.attemptCount = Self.boundAttempt(attemptCount)
        self.status = Self.boundStatus(status)
        self.rateLimitKind = rateLimitKind
        self.retryAfterPresent = retryAfterPresent
        self.retryAfterSeconds = Self.boundRetryAfter(retryAfterSeconds)
        self.routingDecision = routingDecision
        self.reason = reason
        self.accountTelemetryID = Self.safeTelemetryID(accountTelemetryID)
        self.targetAccountTelemetryID = Self.safeTelemetryID(targetAccountTelemetryID)
    }

    private static func utcString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    private static func boundAttempt(_ value: Int?) -> Int? {
        guard let value else { return nil }
        return min(max(0, value), maximumAttempt)
    }

    private static func boundStatus(_ value: Int?) -> Int? {
        guard let value, (100...599).contains(value) else { return nil }
        return value
    }

    private static func boundRetryAfter(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return min(value, maximumRetryAfterSeconds)
    }

    private static func safeTelemetryID(_ value: UUID?) -> UUID? {
        guard let value, value != Account.missingTelemetryID else { return nil }
        return value
    }
}

/// Durable, always-on local routing log. Writes are serialized by the actor,
/// each record is fsynced, and storage is bounded to one active file plus one
/// rotated `.1` file.
public actor RoutingDecisionLog {
    public static let defaultFileName = "routing-decisions-v1.jsonl"

    public nonisolated let fileURL: URL
    public nonisolated let maxBytes: Int

    public init(
        url: URL = AppPaths.supportDir().appendingPathComponent(RoutingDecisionLog.defaultFileName),
        maxBytes: Int = RoutingDecisionLogRecord.maximumActiveBytes
    ) {
        self.fileURL = url
        self.maxBytes = min(max(1, maxBytes), RoutingDecisionLogRecord.maximumActiveBytes)
    }

    /// Persists one allowlisted record. Logging failures are deliberately
    /// swallowed so observability cannot change request-routing behavior.
    public func write(_ record: RoutingDecisionLogRecord) {
        do {
            var data = try Self.encoder.encode(record)
            data.append(0x0A)
            // The schema is bounded, but retain this guard if a future field is
            // accidentally made unbounded rather than violating the file cap.
            guard data.count <= maxBytes else { return }

            let fileManager = FileManager.default
            let directory = fileURL.deletingLastPathComponent()
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

            // The actor protects writes within one process. This stable sidecar
            // lock also serializes the app and standalone swapd processes.
            let lockURL = directory.appendingPathComponent("." + fileURL.lastPathComponent + ".lock")
            let descriptor = open(lockURL.path, O_CREAT | O_RDWR, mode_t(0o600))
            guard descriptor >= 0 else { return }
            defer { close(descriptor) }
            guard flock(descriptor, LOCK_EX) == 0 else { return }
            defer { _ = flock(descriptor, LOCK_UN) }
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: lockURL.path)

            let currentSize = (try? fileManager.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)
                .map(\.intValue) ?? 0
            if currentSize > 0, currentSize + data.count > maxBytes {
                let rotatedURL = fileURL.appendingPathExtension("1")
                if fileManager.fileExists(atPath: rotatedURL.path) {
                    try fileManager.removeItem(at: rotatedURL)
                }
                try fileManager.moveItem(at: fileURL, to: rotatedURL)
                try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: rotatedURL.path)
            }

            if !fileManager.fileExists(atPath: fileURL.path) {
                guard fileManager.createFile(
                    atPath: fileURL.path,
                    contents: nil,
                    attributes: [.posixPermissions: 0o600]
                ) else { return }
            }
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)

            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.synchronize()
        } catch {
            return
        }
    }

    /// Compatibility spelling for callers that model telemetry as an append.
    public func append(_ record: RoutingDecisionLogRecord) {
        write(record)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()
}

extension AppPaths {
    /// Durable local routing decisions. This is metadata-only and never uploaded.
    public static func routingDecisionLogFile() -> URL {
        supportDir().appendingPathComponent(RoutingDecisionLog.defaultFileName)
    }
}
