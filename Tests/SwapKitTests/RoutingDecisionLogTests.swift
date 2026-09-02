import Foundation
import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Darwin)
import Darwin
#endif

@testable import SwapKit

final class RoutingDecisionLogTests: XCTestCase {
    func testGeneric429ExhaustionLogsSwitchReplayAndTerminalOutcome() async throws {
        let upstream = LocalRoutingUpstream(.generic429ThenSuccess(state: "routing-log-generic-switch", retryAfter: "0"))
        let upstreamURL = try await upstream.start()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("routing-log-generic-switch-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = AccountStore(url: root.appendingPathComponent("accounts.json"), strategy: .priority)
        await store.upsert(Account(alias: "hostile-alias", accountID: "hostile-account", accessToken: "token-a", priority: 10))
        await store.upsert(Account(alias: "alternative", accountID: "alternative-account", accessToken: "token-b", priority: 1))
        _ = await store.toggleStickyAlias("hostile-alias")
        var config = ProxyServer.Config()
        config.upstream = upstreamURL
        var settings = Settings.default
        settings.interactiveExhaustionPolicy = .switchFirst
        let capturedSettings = settings
        let log = RoutingDecisionLog(url: root.appendingPathComponent("routing-decisions-v1.jsonl"))
        let server = ProxyServer(
            store: store,
            config: config,
            settingsProvider: { capturedSettings },
            freshAlternative: { _, _ in await store.account("alternative") },
            routingLog: log
        )
        try await server.start()
        let boundPort = await server.port()
        let port: Int = try XCTUnwrap(boundPort)
        let response = try await sendRoutingRequest(port: port, turnKey: "hostile-turn\nAuthorization: Bearer secret")
        XCTAssertEqual(response.statusCode, 200)

        let records = try await readRecordsEventually(at: log.fileURL, minimumCount: 7)
        XCTAssertEqual(records.map(\.event), [
            .requestStarted,
            .genericRetryCurrent, .genericRetryCurrent, .genericRetryCurrent,
            .genericExhausted,
            .switchReplay,
            .requestTerminal
        ])
        XCTAssertEqual(records.first?.rootRequestID, records.last?.rootRequestID)
        XCTAssertEqual(records.filter { $0.event == .genericRetryCurrent }.count, 3)
        XCTAssertEqual(records.first { $0.event == .genericExhausted }?.rateLimitKind, .generic)
        XCTAssertEqual(records.first { $0.event == .switchReplay }?.routingDecision, .switchToAlternative)
        XCTAssertEqual(records.last?.status, 200)
        let serialized = String(decoding: try Data(contentsOf: log.fileURL), as: UTF8.self)
        XCTAssertFalse(serialized.contains("hostile-alias"))
        XCTAssertFalse(serialized.contains("Authorization"))
        XCTAssertFalse(serialized.contains("Bearer secret"))

        await server.stop()
        await upstream.stop()
    }

    func testGeneric429ExhaustionLogsNoTargetStopWhenSwitchHasNoAlternative() async throws {
        let upstream = LocalRoutingUpstream(.generic429ThenSuccess(state: "routing-log-generic-stop", retryAfter: "0"))
        let upstreamURL = try await upstream.start()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("routing-log-generic-stop-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = AccountStore(url: root.appendingPathComponent("accounts.json"), strategy: .priority)
        await store.upsert(Account(alias: "only-account", accountID: "only-account", accessToken: "token-a", priority: 10))
        _ = await store.toggleStickyAlias("only-account")
        var config = ProxyServer.Config()
        config.upstream = upstreamURL
        var settings = Settings.default
        settings.interactiveExhaustionPolicy = .switchFirst
        let capturedSettings = settings
        let log = RoutingDecisionLog(url: root.appendingPathComponent("routing-decisions-v1.jsonl"))
        let server = ProxyServer(
            store: store,
            config: config,
            settingsProvider: { capturedSettings },
            routingLog: log
        )

        try await server.start()
        let boundPort = await server.port()
        let port: Int = try XCTUnwrap(boundPort)
        let response = try await sendRoutingRequest(port: port, turnKey: "generic-no-target")
        XCTAssertEqual(response.statusCode, 429)

        let records = try await readRecordsEventually(at: log.fileURL, minimumCount: 7)
        XCTAssertEqual(records.map(\.event), [
            .requestStarted,
            .genericRetryCurrent, .genericRetryCurrent, .genericRetryCurrent,
            .genericExhausted,
            .noTargetStop,
            .requestTerminal
        ])
        XCTAssertEqual(records.first { $0.event == .noTargetStop }?.routingDecision, .stop)
        XCTAssertEqual(records.first { $0.event == .noTargetStop }?.reason, .policyStop)
        XCTAssertEqual(records.last?.status, 429)

        await server.stop()
        await upstream.stop()
    }

    func testSemantic429LogsLimitAndSwitchReplay() async throws {
        let upstream = LocalRoutingUpstream(.usageLimitFirst(state: "routing-log-semantic-switch"))
        let upstreamURL = try await upstream.start()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("routing-log-semantic-switch-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = AccountStore(url: root.appendingPathComponent("accounts.json"), strategy: .priority)
        await store.upsert(Account(alias: "semantic-source", accountID: "semantic-source", accessToken: "token-a", priority: 10))
        await store.upsert(Account(alias: "semantic-target", accountID: "semantic-target", accessToken: "token-b", priority: 1))
        _ = await store.toggleStickyAlias("semantic-source")
        var config = ProxyServer.Config()
        config.upstream = upstreamURL
        let log = RoutingDecisionLog(url: root.appendingPathComponent("routing-decisions-v1.jsonl"))
        let server = ProxyServer(
            store: store,
            config: config,
            settingsProvider: { .default },
            freshAlternative: { _, _ in await store.account("semantic-target") },
            routingLog: log
        )

        try await server.start()
        let boundPort = await server.port()
        let port: Int = try XCTUnwrap(boundPort)
        let response = try await sendRoutingRequest(port: port, turnKey: "semantic-turn")
        XCTAssertEqual(response.statusCode, 200)

        let records = try await readRecordsEventually(at: log.fileURL, minimumCount: 4)
        XCTAssertEqual(records.map(\.event), [
            .requestStarted,
            .semanticLimit,
            .switchReplay,
            .requestTerminal
        ])
        XCTAssertEqual(records[1].rateLimitKind, .semantic)
        XCTAssertEqual(records[1].status, 429)
        XCTAssertEqual(records[2].routingDecision, .switchToAlternative)
        XCTAssertEqual(records.last?.status, 200)

        await server.stop()
        await upstream.stop()
    }

    func testRecordUsesStableSchemaUtcTimestampAndOnlyAllowlistedFields() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("routing-log-schema-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let log = RoutingDecisionLog(url: root.appendingPathComponent("routing-decisions-v1.jsonl"))
        let requestID = UUID()
        let accountID = UUID()
        await log.write(RoutingDecisionLogRecord(
            event: .semanticLimit,
            rootRequestID: requestID,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            attempt: 1,
            status: 429,
            rateLimitKind: .semantic,
            retryAfterPresent: false,
            routingDecision: .switchToAlternative,
            reason: .semanticLimit,
            accountTelemetryID: accountID,
            targetAccountTelemetryID: UUID()
        ))

        let data = try Data(contentsOf: log.fileURL)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(object["schemaVersion"] as? Int, RoutingDecisionLogRecord.schemaVersion)
        XCTAssertEqual(object["event"] as? String, "semantic_limit")
        XCTAssertEqual(object["rootRequestID"] as? String, requestID.uuidString)
        XCTAssertEqual(object["timestamp"] as? String, "2023-11-14T22:13:20.000Z")
        XCTAssertEqual(object["status"] as? Int, 429)
        XCTAssertEqual(object["rateLimitKind"] as? String, "semantic")
        XCTAssertEqual(object["retryAfterPresent"] as? Bool, false)
        XCTAssertEqual(object["routingDecision"] as? String, "switch_to_alternative")
        XCTAssertEqual(object["reason"] as? String, "semantic_limit")
        XCTAssertEqual(object["accountTelemetryID"] as? String, accountID.uuidString)
        let allowed = Set([
            "schemaVersion", "timestamp", "event", "rootRequestID", "attempt",
            "attemptCount", "status", "rateLimitKind", "retryAfterPresent",
            "retryAfterSeconds", "routingDecision", "reason", "accountTelemetryID",
            "targetAccountTelemetryID"
        ])
        XCTAssertTrue(Set(object.keys).isSubset(of: allowed))
    }

    func testHostileValuesCannotEnterStructuredRecord() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("routing-log-redaction-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let log = RoutingDecisionLog(url: root.appendingPathComponent("routing-decisions-v1.jsonl"))
        await log.write(RoutingDecisionLogRecord(
            event: .requestTerminal,
            rootRequestID: UUID(),
            timestamp: Date(),
            attempt: 999_999,
            attemptCount: -4,
            status: 999_999,
            retryAfterPresent: true,
            retryAfterSeconds: 9_999,
            routingDecision: .failure,
            reason: .terminalFailure
        ))

        let raw = String(decoding: try Data(contentsOf: log.fileURL), as: UTF8.self)
        XCTAssertFalse(raw.contains("prompt"))
        XCTAssertFalse(raw.contains("response"))
        XCTAssertFalse(raw.contains("Authorization"))
        XCTAssertFalse(raw.contains("Bearer"))
        XCTAssertFalse(raw.contains("alias@example.com"))
        XCTAssertFalse(raw.contains("session-secret"))
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any]
        )
        XCTAssertEqual(object["attempt"] as? Int, 64)
        XCTAssertEqual(object["attemptCount"] as? Int, 0)
        XCTAssertNil(object["status"])
        XCTAssertEqual(object["retryAfterSeconds"] as? Double, 30)
    }

    func testActiveLogRotatesToOneBoundedPrivateBackup() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("routing-log-rotation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let active = root.appendingPathComponent("routing-decisions-v1.jsonl")
        let log = RoutingDecisionLog(url: active, maxBytes: 512)
        for _ in 0..<20 {
            await log.write(RoutingDecisionLogRecord(
                event: .requestStarted,
                rootRequestID: UUID(),
                timestamp: Date(),
                reason: .requestStart
            ))
        }

        let rotated = active.appendingPathExtension("1")
        XCTAssertTrue(FileManager.default.fileExists(atPath: active.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: rotated.path))
        let activeSize = try XCTUnwrap(
            (try FileManager.default.attributesOfItem(atPath: active.path)[.size] as? NSNumber)?.intValue
        )
        let rotatedSize = try XCTUnwrap(
            (try FileManager.default.attributesOfItem(atPath: rotated.path)[.size] as? NSNumber)?.intValue
        )
        XCTAssertLessThanOrEqual(activeSize, 512)
        XCTAssertLessThanOrEqual(rotatedSize, 512)

        let directoryMode = try XCTUnwrap(
            (try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? NSNumber)?.intValue
        )
        let activeMode = try XCTUnwrap(
            (try FileManager.default.attributesOfItem(atPath: active.path)[.posixPermissions] as? NSNumber)?.intValue
        )
        let rotatedMode = try XCTUnwrap(
            (try FileManager.default.attributesOfItem(atPath: rotated.path)[.posixPermissions] as? NSNumber)?.intValue
        )
        XCTAssertEqual(directoryMode & 0o777, 0o700)
        XCTAssertEqual(activeMode & 0o777, 0o600)
        XCTAssertEqual(rotatedMode & 0o777, 0o600)
    }

    func testConcurrentWritersProduceOnlyCompleteRecordsWithinRetention() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("routing-log-concurrent-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let active = root.appendingPathComponent("routing-decisions-v1.jsonl")

        #if canImport(Darwin)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let lockURL = root.appendingPathComponent(".routing-decisions-v1.jsonl.lock")
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, mode_t(0o600))
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        XCTAssertEqual(flock(descriptor, LOCK_EX), 0)

        let blockedMarker = root.appendingPathComponent("blocked.ready")
        let blocked = try launchWriterProcess(active: active, marker: blockedMarker, count: 100)
        try waitForFile(blockedMarker)
        XCTAssertFalse(FileManager.default.fileExists(atPath: active.path))

        XCTAssertEqual(flock(descriptor, LOCK_UN), 0)
        blocked.waitUntilExit()
        XCTAssertEqual(blocked.terminationStatus, 0)

        let firstMarker = root.appendingPathComponent("first.ready")
        let secondMarker = root.appendingPathComponent("second.ready")
        let first = try launchWriterProcess(active: active, marker: firstMarker, count: 100)
        let second = try launchWriterProcess(active: active, marker: secondMarker, count: 100)
        try waitForFile(firstMarker)
        try waitForFile(secondMarker)
        first.waitUntilExit()
        second.waitUntilExit()
        XCTAssertEqual(first.terminationStatus, 0)
        XCTAssertEqual(second.terminationStatus, 0)

        let records = try await readRecordsEventually(at: active, minimumCount: 300)
        XCTAssertEqual(records.count, 300)
        XCTAssertTrue(records.allSatisfy { $0.schemaVersion == RoutingDecisionLogRecord.schemaVersion })
        let activeSize = try XCTUnwrap(
            (try FileManager.default.attributesOfItem(atPath: active.path)[.size] as? NSNumber)?.intValue
        )
        XCTAssertLessThanOrEqual(activeSize, RoutingDecisionLogRecord.maximumActiveBytes)
        #else
        throw XCTSkip("The interprocess flock test requires Darwin")
        #endif
    }

    /// Entry point used by `testConcurrentWritersProduceOnlyCompleteRecordsWithinRetention`.
    /// It is a no-op during the normal test run and activated only by a child xctest process.
    func testWriteConcurrentRecordsForHelperProcess() async throws {
        guard
            let path = ProcessInfo.processInfo.environment["ROUTING_LOG_WRITER_PATH"],
            let countString = ProcessInfo.processInfo.environment["ROUTING_LOG_WRITER_COUNT"],
            let count = Int(countString)
        else {
            return
        }
        if let marker = ProcessInfo.processInfo.environment["ROUTING_LOG_WRITER_MARKER"] {
            FileManager.default.createFile(atPath: marker, contents: nil, attributes: [.posixPermissions: 0o600])
        }

        let log = RoutingDecisionLog(url: URL(fileURLWithPath: path))
        for _ in 0..<count {
            await log.write(RoutingDecisionLogRecord(
                event: .requestStarted,
                rootRequestID: UUID(),
                reason: .requestStart
            ))
        }
    }

    private func sendRoutingRequest(port: Int, turnKey: String) async throws -> HTTPURLResponse {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/backend-api/codex/responses")!)
        request.httpMethod = "POST"
        request.httpBody = Data(#"{}"#.utf8)
        request.timeoutInterval = 5
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(turnKey, forHTTPHeaderField: "x-codex-turn-metadata")
        let (_, response) = try await URLSession.shared.data(for: request)
        return try XCTUnwrap(response as? HTTPURLResponse)
    }

    private func readRecords(at url: URL) async throws -> [RoutingDecisionLogRecord] {
        // The actor has completed each write before this read starts. Decode one
        // JSON object per line to mirror the supported read-only inspection path.
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        return try String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .map { try decoder.decode(RoutingDecisionLogRecord.self, from: Data($0.utf8)) }
    }

    private func readRecordsEventually(at url: URL, minimumCount: Int) async throws -> [RoutingDecisionLogRecord] {
        for _ in 0..<100 {
            if let records = try? await readRecords(at: url), records.count >= minimumCount {
                return records
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        return try await readRecords(at: url)
    }

    #if canImport(Darwin)
    private func launchWriterProcess(active: URL, marker: URL, count: Int) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = [
            "xctest",
            "-XCTest",
            "SwapKitTests.RoutingDecisionLogTests/testWriteConcurrentRecordsForHelperProcess",
            Bundle(for: RoutingDecisionLogTests.self).bundleURL.path
        ]
        process.environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "ROUTING_LOG_WRITER_PATH": active.path,
            "ROUTING_LOG_WRITER_MARKER": marker.path,
            "ROUTING_LOG_WRITER_COUNT": String(count)
        ]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        return process
    }

    private func waitForFile(_ url: URL) throws {
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: url.path) {
                return
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        throw NSError(domain: "RoutingDecisionLogTests", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Timed out waiting for child writer marker"
        ])
    }
    #endif
}
