import Foundation
import XCTest
@testable import SwapKit

final class DiagnosticsOperationTests: XCTestCase {
    func testWarmupOfflineSkipRecordsBoundedLifecycle() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let log = DiagnosticsLog(url: root.appendingPathComponent("diagnostics.jsonl"))
        let service = QuotaWarmupService(
            runner: DiagnosticsNoopWarmupRunner(),
            ledger: WarmupLedgerStore(url: root.appendingPathComponent("warmup.json")),
            networkCheck: { false },
            diagnosticsLog: log
        )

        let summary = await service.run(
            accounts: [],
            proxyURL: URL(string: "http://127.0.0.1:58432")!,
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )

        XCTAssertEqual(summary.skipped["all"], "network unavailable")
        let records = log.snapshot().records.filter { $0.component == .warmup }
        XCTAssertEqual(records.count, 2)
        XCTAssertTrue(records.contains { $0.outcome.rawValue == "started" })
        let skipped = records.first { $0.outcome.rawValue == "skipped" }
        XCTAssertEqual(skipped?.code, .network)
        XCTAssertEqual(skipped?.count, 0)
    }

    func testWarmupCancellationIsNotReportedAsTimeoutOrFailure() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let log = DiagnosticsLog(url: root.appendingPathComponent("diagnostics.jsonl"))
        let service = QuotaWarmupService(
            runner: DiagnosticsCancelledWarmupRunner(),
            ledger: WarmupLedgerStore(url: root.appendingPathComponent("warmup.json")),
            diagnosticsLog: log
        )
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let account = Account(
            alias: "synthetic",
            accessToken: "synthetic-token",
            usage: [UsageWindow(label: "5h", usedPercent: 0, windowSeconds: 18_000, resetAt: now.addingTimeInterval(18_000))]
        )

        let summary = await service.run(
            accounts: [account],
            proxyURL: URL(string: "http://127.0.0.1:58432")!,
            force: true,
            now: now
        )

        XCTAssertEqual(summary.skipped[account.alias], "cancelled")
        XCTAssertTrue(summary.failed.isEmpty)
        let records = log.snapshot().records.filter { $0.component == .warmup }
        XCTAssertTrue(records.contains { $0.operation == .request && $0.outcome == .cancelled && $0.code == .none })
        XCTAssertTrue(records.contains { $0.operation == .warmup && $0.outcome == .cancelled && $0.code == .none })
        XCTAssertFalse(records.contains { $0.code == .timeout || $0.outcome == .failed })
    }

    func testResetInvalidAliasRecordsTerminalFailureMapping() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let log = DiagnosticsLog(url: root.appendingPathComponent("diagnostics.jsonl"))
        let store = AccountStore(url: root.appendingPathComponent("accounts.json"))
        let coordinator = QuotaResetCoordinator(
            accountStore: store,
            settings: { .default },
            resetService: DiagnosticsNoopResetService(),
            usageService: DiagnosticsNoopUsageFetcher(),
            pendingRecordURL: root.appendingPathComponent("pending.json"),
            diagnosticsLog: log
        )

        let result = await coordinator.reset(alias: "   ", trigger: .manual)

        XCTAssertEqual(result, .accountUnavailable)
        let records = log.snapshot().records.filter { $0.component == .quota && $0.operation == .reset }
        XCTAssertEqual(records.count, 2)
        XCTAssertTrue(records.contains { $0.outcome.rawValue == "started" })
        XCTAssertEqual(records.first { $0.outcome.rawValue == "skipped" }?.code, .notFound)
    }

    func testAccountStoreLockPreparationFailureIsVisible() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let blockedParent = root.appendingPathComponent("blocked")
        try Data("not-a-directory".utf8).write(to: blockedParent)
        let before = DiagnosticsLog.shared.snapshot().records.count
        let store = AccountStore(url: blockedParent.appendingPathComponent("accounts.json"))

        await store.upsert(Account(alias: "synthetic"))

        let records = DiagnosticsLog.shared.snapshot().records
        XCTAssertGreaterThan(records.count, before)
        XCTAssertTrue(records.suffix(from: min(before, records.count)).contains {
            $0.component == .accounts && $0.operation == .persistence
                && $0.outcome == .failed && $0.code == .io
        })
    }

    func testTaskStartFailureRecordsTerminalFailureWithoutPaths() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let log = DiagnosticsLog(url: root.appendingPathComponent("diagnostics.jsonl"))
        let runner = TaskRunner(codexBinaryResolver: { "/usr/bin/true" }, diagnosticsLog: log)
        let runID = UUID()
        let task = AutomationTask(
            title: "diagnostic test",
            prompt: "test",
            repoPath: root.appendingPathComponent("not-a-repository").path,
            branch: "main"
        )

        do {
            try await runner.start(
                task: task,
                allowedAliases: [],
                runID: runID,
                proxyURL: URL(string: "http://127.0.0.1:58432")!,
                supportDir: root.appendingPathComponent("support"),
                onExit: { _, _ in }
            )
            XCTFail("expected invalid repository")
        } catch let error as TaskRunnerError {
            guard case .invalidRepository = error else {
                XCTFail("expected invalid repository, got \(error)")
                return
            }
        }

        let records = log.snapshot().records.filter { $0.component == .tasks && $0.correlationID == runID }
        XCTAssertEqual(records.count, 2)
        XCTAssertTrue(records.contains { $0.outcome.rawValue == "started" })
        XCTAssertEqual(records.first { $0.outcome.rawValue == "failed" }?.code, .invalidInput)
        let data = try log.exportData()
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains(task.repoPath))
    }

    func testTaskMaterializationFailureRecordsOneTerminalFailure() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = root.appendingPathComponent("repository", isDirectory: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        let git = Process()
        git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        git.arguments = ["-C", repository.path, "init", "--quiet"]
        git.standardOutput = FileHandle.nullDevice
        git.standardError = FileHandle.nullDevice
        try git.run()
        git.waitUntilExit()
        XCTAssertEqual(git.terminationStatus, 0)

        let log = DiagnosticsLog(url: root.appendingPathComponent("diagnostics.jsonl"))
        let runner = TaskRunner(
            taskHomeMaterializer: { _, _, _, _, _ in throw DiagnosticsSyntheticError.failed },
            codexBinaryResolver: { "/usr/bin/true" },
            diagnosticsLog: log
        )
        let runID = UUID()
        let task = AutomationTask(title: "diagnostic test", prompt: "test", repoPath: repository.path, branch: "main")

        do {
            try await runner.start(
                task: task,
                allowedAliases: [],
                runID: runID,
                proxyURL: URL(string: "http://127.0.0.1:58432")!,
                supportDir: root.appendingPathComponent("support"),
                onExit: { _, _ in }
            )
            XCTFail("expected materialization failure")
        } catch is DiagnosticsSyntheticError {
        }

        let records = log.snapshot().records.filter { $0.component == .tasks && $0.correlationID == runID }
        XCTAssertEqual(records.count, 2)
        XCTAssertTrue(records.contains { $0.outcome.rawValue == "started" })
        XCTAssertEqual(records.first { $0.outcome.rawValue == "failed" }?.code, .io)
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("diagnostics-operation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}

private struct DiagnosticsNoopWarmupRunner: WarmupCommandRunning {
    func run(alias: String, proxyURL: URL) async throws {}
}

private struct DiagnosticsCancelledWarmupRunner: WarmupCommandRunning {
    func run(alias: String, proxyURL: URL) async throws { throw CancellationError() }
}

private struct DiagnosticsNoopResetService: QuotaResetServing {
    func credits(accessToken: String, accountID: String) async throws -> ResetCreditSnapshot {
        ResetCreditSnapshot(availableCount: 0, credits: [], fetchedAt: Date())
    }

    func consume(accessToken: String, accountID: String, creditID: String, redemptionID: UUID) async throws -> ResetConsumeResult {
        ResetConsumeResult(outcome: .noCredit, windowsReset: 0)
    }
}

private struct DiagnosticsNoopUsageFetcher: UsageFetching {
    func fetch(accessToken: String, accountID: String) async throws -> [UsageWindow] { [] }
}

private enum DiagnosticsSyntheticError: Error {
    case failed
}
