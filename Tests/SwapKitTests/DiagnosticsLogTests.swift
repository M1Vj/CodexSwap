import Foundation
import XCTest
@testable import SwapKit

final class DiagnosticsLogTests: XCTestCase {
    func testRecordsRotateWithinConfiguredRetention() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("diagnostics-v1.jsonl")
        let log = DiagnosticsLog(url: url, maxBytes: 512, retainedFiles: 4)

        for _ in 0..<32 {
            log.record(
                component: .proxy,
                operation: .request,
                outcome: .succeeded,
                level: .info,
                durationMilliseconds: 10,
                count: 1
            )
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let rotationURLs = (1...3).map { url.appendingPathExtension(String($0)) }
        XCTAssertTrue(rotationURLs.contains { FileManager.default.fileExists(atPath: $0.path) })
        let paths = [url] + rotationURLs
        var totalBytes = 0
        for candidate in paths where FileManager.default.fileExists(atPath: candidate.path) {
            let attributes = try FileManager.default.attributesOfItem(atPath: candidate.path)
            let bytes = try XCTUnwrap((attributes[.size] as? NSNumber)?.intValue)
            XCTAssertLessThanOrEqual(bytes, 512)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0 & 0o777, 0o600)
            totalBytes += bytes
        }
        XCTAssertLessThanOrEqual(totalBytes, 512 * 4)
        XCTAssertEqual(log.snapshot().retentionBytes, 512 * 4)
    }

    func testSingleRetainedFileContinuesByTruncatingOwnedActiveFile() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("diagnostics-v1.jsonl")
        let log = DiagnosticsLog(url: url, maxBytes: 512, retainedFiles: 1)

        for _ in 0..<24 {
            log.record(component: .storage, operation: .persistence, outcome: .succeeded)
        }

        let snapshot = log.snapshot()
        XCTAssertFalse(snapshot.records.isEmpty)
        XCTAssertEqual(snapshot.retentionBytes, 512)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.appendingPathExtension("1").path))
    }

    func testDirectoryAndFilesUsePrivatePermissions() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("diagnostics-v1.jsonl")
        let log = DiagnosticsLog(url: url, maxBytes: 2048, retainedFiles: 2)
        log.record(component: .app, operation: .lifecycle, outcome: .started)

        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: root.path)
        XCTAssertEqual((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue ?? 0 & 0o777, 0o700)
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((fileAttributes[.posixPermissions] as? NSNumber)?.intValue ?? 0 & 0o777, 0o600)
        let lockURL = root.appendingPathComponent(".diagnostics-v1.jsonl.lock")
        XCTAssertTrue(FileManager.default.fileExists(atPath: lockURL.path))
        let lockAttributes = try FileManager.default.attributesOfItem(atPath: lockURL.path)
        XCTAssertEqual((lockAttributes[.posixPermissions] as? NSNumber)?.intValue ?? 0 & 0o777, 0o600)
    }

    func testParallelWritersProduceBoundedDecodableRecords() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("diagnostics-v1.jsonl")
        let logs = (0..<8).map { _ in DiagnosticsLog(url: url, maxBytes: 16_384, retainedFiles: 4) }
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "diagnostics-parallel", attributes: .concurrent)
        for log in logs {
            group.enter()
            queue.async {
                for _ in 0..<24 {
                    log.record(component: .routing, operation: .selection, outcome: .changed, correlationID: UUID())
                }
                group.leave()
            }
        }
        group.wait()

        let snapshot = logs[0].snapshot(limit: 500)
        XCTAssertFalse(snapshot.records.isEmpty)
        XCTAssertLessThanOrEqual(snapshot.readFailures, 1)
        XCTAssertLessThanOrEqual(snapshot.droppedRecords, 8 * 24)
    }

    func testSnapshotFiltersByComponentAndMinimumLevel() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let log = DiagnosticsLog(url: root.appendingPathComponent("diagnostics-v1.jsonl"), maxBytes: 16_384)
        log.record(component: .proxy, operation: .request, outcome: .started, level: .debug)
        log.record(component: .proxy, operation: .request, outcome: .failed, level: .error, code: .network)
        log.record(component: .quota, operation: .usageFetch, outcome: .succeeded, level: .info)

        let filtered = log.snapshot(limit: 10, component: .proxy, minimumLevel: .warning)
        XCTAssertEqual(filtered.records.count, 1)
        XCTAssertEqual(filtered.records.first?.component, .proxy)
        XCTAssertEqual(filtered.records.first?.level, .error)
        XCTAssertEqual(filtered.records.first?.code, .network)
    }

    func testRecordRoundTripsThroughSnapshotAndExport() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let log = DiagnosticsLog(url: root.appendingPathComponent("diagnostics-v1.jsonl"), maxBytes: 16_384)
        let correlationID = UUID()
        log.record(
            component: .tasks,
            operation: .taskRun,
            outcome: .failed,
            level: .error,
            code: .timeout,
            correlationID: correlationID,
            status: 504,
            durationMilliseconds: 1_250,
            count: 2
        )

        let snapshot = log.snapshot()
        let record = try XCTUnwrap(snapshot.records.first)
        XCTAssertEqual(record.component, .tasks)
        XCTAssertEqual(record.operation, .taskRun)
        XCTAssertEqual(record.outcome, .failed)
        XCTAssertEqual(record.level, .error)
        XCTAssertEqual(record.code, .timeout)
        XCTAssertEqual(record.correlationID, correlationID)
        XCTAssertEqual(record.status, 504)
        XCTAssertEqual(record.durationMilliseconds, 1_250)
        XCTAssertEqual(record.count, 2)

        let data = try log.exportData(limit: 10)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["schemaVersion"] as? Int, 1)
        XCTAssertNotNil(object["currentTime"] as? String)
        XCTAssertNotNil(object["records"] as? [[String: Any]])
        XCTAssertNil(object["appVersion"])
        XCTAssertNil(object["build"])
    }

    func testPublicRecordAPIHasNoFreeformPayloadAndBoundsNumbers() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let log = DiagnosticsLog(url: root.appendingPathComponent("diagnostics-v1.jsonl"), maxBytes: 16_384)
        log.record(
            component: .diagnostics,
            operation: .export,
            outcome: .changed,
            status: Int.max,
            durationMilliseconds: Int.max,
            count: Int.max
        )

        let data = try Data(contentsOf: root.appendingPathComponent("diagnostics-v1.jsonl"))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(object["message"])
        XCTAssertNil(object["error"])
        XCTAssertNil(object["path"])
        XCTAssertNil(object["prompt"])
        XCTAssertNil(object["token"])
        XCTAssertNil(object["status"])
        XCTAssertLessThan((object["durationMilliseconds"] as? Int) ?? Int.max, Int.max)
        XCTAssertLessThan((object["count"] as? Int) ?? Int.max, Int.max)
    }

    func testDiagnosticCodeClassifiesTypedErrorsWithoutFreeformText() {
        XCTAssertEqual(DiagnosticCode.classify(URLError(.timedOut)), .timeout)
        XCTAssertEqual(DiagnosticCode.classify(URLError(.userAuthenticationRequired)), .unauthorized)
        XCTAssertEqual(DiagnosticCode.classify(CocoaError(.fileReadNoPermission)), .unauthorized)
        XCTAssertEqual(DiagnosticCode.classify(UsageClient.UsageError.unauthorized), .unauthorized)
        XCTAssertEqual(DiagnosticCode.classify(UsageClient.UsageError.http(403)), .unauthorized)
        XCTAssertEqual(DiagnosticCode.classify(UsageClient.UsageError.http(429)), .rateLimited)
        XCTAssertEqual(DiagnosticCode.classify(UsageClient.UsageError.http(503)), .unavailable)
        XCTAssertEqual(DiagnosticCode.classify(UsageClient.UsageError.malformed), .invalidInput)
        XCTAssertEqual(DiagnosticCode.classify(CancellationError()), .none)
        XCTAssertEqual(DiagnosticCode.classify(TestError()), .unknown)
    }

    func testMalformedRecordsAreSkippedWithoutUnboundedRead() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("diagnostics-v1.jsonl")
        try Data("not-json\n{\"component\":\"proxy\"}\n".utf8).write(to: url)
        let log = DiagnosticsLog(url: url, maxBytes: 64, retainedFiles: 2)

        let snapshot = log.snapshot(limit: 100)
        XCTAssertTrue(snapshot.records.isEmpty)
        XCTAssertGreaterThan(snapshot.readFailures, 0)
    }

    func testOutOfRangeTimestampIsRejected() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("diagnostics-v1.jsonl")
        let hugeTimestamp = #"{"id":"00000000-0000-0000-0000-000000000001","timestamp":1e308,"processSessionID":"00000000-0000-0000-0000-000000000002","component":"proxy","operation":"request","outcome":"started","level":"info","code":"none"}"#
        try Data((hugeTimestamp + "\n").utf8).write(to: url)
        let log = DiagnosticsLog(url: url, maxBytes: 512)

        XCTAssertTrue(log.snapshot().records.isEmpty)
        XCTAssertGreaterThan(log.snapshot().readFailures, 0)
    }

    func testSymlinkedActiveAndRotationFilesAreRejected() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("target")
        try Data("outside\n".utf8).write(to: target)
        let active = root.appendingPathComponent("diagnostics-v1.jsonl")
        try FileManager.default.createSymbolicLink(at: active, withDestinationURL: target)
        let activeLog = DiagnosticsLog(url: active, maxBytes: 512)
        activeLog.record(component: .storage, operation: .persistence, outcome: .failed, level: .error, code: .io)
        XCTAssertEqual(activeLog.snapshot().writeFailures, 1)
        XCTAssertEqual(String(decoding: try Data(contentsOf: target), as: UTF8.self), "outside\n")

        try? FileManager.default.removeItem(at: active)
        let normalLog = DiagnosticsLog(url: active, maxBytes: 512)
        normalLog.record(component: .storage, operation: .persistence, outcome: .succeeded)
        let rotated = active.appendingPathExtension("1")
        try? FileManager.default.removeItem(at: rotated)
        try FileManager.default.createSymbolicLink(at: rotated, withDestinationURL: target)
        normalLog.record(component: .storage, operation: .persistence, outcome: .succeeded)
        XCTAssertGreaterThan(normalLog.snapshot().writeFailures, 0)
    }

    func testSymlinkedParentDirectoryIsRejectedWithoutWritingOutsideTarget() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let realDirectory = root.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: realDirectory, withIntermediateDirectories: true)
        let linkedDirectory = root.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linkedDirectory, withDestinationURL: realDirectory)
        let log = DiagnosticsLog(url: linkedDirectory.appendingPathComponent("nested/diagnostics-v1.jsonl"), maxBytes: 512)

        log.record(component: .storage, operation: .persistence, outcome: .failed, level: .error, code: .io)

        XCTAssertEqual(log.snapshot().writeFailures, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: realDirectory.appendingPathComponent("nested").path))
    }

    func testHardlinkedActiveAndLockFilesAreRejected() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let active = root.appendingPathComponent("diagnostics-v1.jsonl")
        let hardlink = root.appendingPathComponent("outside-active")
        try Data("owned\n".utf8).write(to: active)
        try FileManager.default.linkItem(at: active, to: hardlink)
        let activeLog = DiagnosticsLog(url: active, maxBytes: 512)
        activeLog.record(component: .storage, operation: .persistence, outcome: .succeeded)
        XCTAssertGreaterThan(activeLog.snapshot().writeFailures, 0)
        XCTAssertEqual(String(decoding: try Data(contentsOf: hardlink), as: UTF8.self), "owned\n")

        let lockActive = root.appendingPathComponent("lock-diagnostics-v1.jsonl")
        let lockURL = root.appendingPathComponent(".lock-diagnostics-v1.jsonl.lock")
        let lockHardlink = root.appendingPathComponent("outside-lock")
        try Data().write(to: lockURL)
        try FileManager.default.linkItem(at: lockURL, to: lockHardlink)
        let lockLog = DiagnosticsLog(url: lockActive, maxBytes: 512)
        lockLog.record(component: .storage, operation: .persistence, outcome: .succeeded)
        XCTAssertGreaterThan(lockLog.snapshot().writeFailures, 0)
    }

    func testVisibleIOFailureIsExposedBySnapshot() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let blockedDirectory = root.appendingPathComponent("blocked")
        try Data("not-a-directory".utf8).write(to: blockedDirectory)
        let invalidURL = blockedDirectory.appendingPathComponent("nested/diagnostics-v1.jsonl")
        let log = DiagnosticsLog(url: invalidURL, maxBytes: 512)
        log.record(component: .storage, operation: .persistence, outcome: .failed, level: .error, code: .io)

        XCTAssertGreaterThan(log.snapshot().writeFailures, 0)
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("diagnostics-log-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private struct TestError: Error {}
}
