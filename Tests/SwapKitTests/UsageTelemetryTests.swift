import XCTest
import Foundation
@testable import SwapKit

final class UsageTelemetryTests: XCTestCase {
    private let accountID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let otherAccountID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    private func makeStore(
        now: Date = Date(timeIntervalSince1970: 1_700_000_000),
        enabled: Bool = true,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> (UsageTelemetryStore, URL, () -> Void) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexswap-telemetry-\(UUID().uuidString)", isDirectory: true)
        let url = root.appendingPathComponent("usage-telemetry-v1.json")
        let store = UsageTelemetryStore(url: url, enabled: enabled, clock: { now })
        return (store, url, { try? FileManager.default.removeItem(at: root) })
    }

    private func event(
        id: UUID = UUID(),
        root: UUID = UUID(),
        account: UUID? = nil,
        startedAt: Date = Date(timeIntervalSince1970: 1_700_000_000 - 1),
        finishedAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
        attemptIndex: Int = 0,
        provider: UsageTelemetryProviderFamily = .openAI,
        model: String = "gpt-5.6-sol",
        category: UsageTelemetryRequestCategory = .interactive,
        outcome: UsageTelemetryAttemptOutcome = .success,
        status: Int? = nil,
        error: UsageTelemetryErrorClass? = nil,
        input: Int? = 100,
        cached: Int? = 20,
        cacheWrite: Int? = 5,
        output: Int? = 40,
        reasoning: Int? = 10,
        duration: Int? = nil,
        firstChunk: Int? = nil,
        taskRunID: UUID? = nil,
        cost: Double? = nil
    ) -> UsageTelemetryAttemptEvent {
        UsageTelemetryAttemptEvent(
            eventID: id,
            rootRequestID: root,
            attemptIndex: attemptIndex,
            startedAt: startedAt,
            finishedAt: finishedAt,
            firstChunkAt: nil,
            accountTelemetryID: account ?? accountID,
            provider: provider,
            model: model,
            category: category,
            taskBoardRunID: taskRunID,
            outcome: outcome,
            httpStatusCode: status,
            errorClass: error,
            durationMilliseconds: duration,
            timeToFirstChunkMilliseconds: firstChunk,
            inputTokens: input,
            cachedInputTokens: cached,
            cacheWriteInputTokens: cacheWrite,
            outputTokens: output,
            reasoningTokens: reasoning,
            estimatedCostUSD: cost,
            costCompleteness: cost == nil ? nil : .complete,
            pricingSource: cost == nil ? nil : "test-pricing",
            pricingRevision: cost == nil ? nil : "v1"
        )
    }

    func testSettingsDefaultAndMigrationKeepTelemetryOff() throws {
        XCTAssertFalse(Settings.default.metadataTelemetryEnabled)
        let decoded = try JSONDecoder().decode(Settings.self, from: Data("{}".utf8))
        XCTAssertFalse(decoded.metadataTelemetryEnabled)

        var enabled = Settings.default
        enabled.metadataTelemetryEnabled = true
        let roundTrip = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(enabled))
        XCTAssertTrue(roundTrip.metadataTelemetryEnabled)
    }

    func testSettingsStoreTelemetryToggleUsesExistingPersistencePath() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexswap-settings-telemetry-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = SettingsStore(url: url)
        let initiallyEnabled = await store.metadataTelemetryEnabled()
        XCTAssertFalse(initiallyEnabled)
        _ = await store.setMetadataTelemetryEnabled(true)
        let enabled = await store.metadataTelemetryEnabled()
        XCTAssertTrue(enabled)
        let reloaded = SettingsStore(url: url)
        let persisted = await reloaded.metadataTelemetryEnabled()
        XCTAssertTrue(persisted)
    }

    func testStrictEventAllowlistNormalizesDimensionsAndExcludesContentShapedCanaries() async throws {
        let (store, url, cleanup) = makeStore()
        defer { cleanup() }
        let canary = event(
            provider: .other,
            model: "prompt-canary /Users/vj/private response-canary",
            category: .taskBoard,
            taskRunID: UUID(uuidString: "33333333-3333-3333-3333-333333333333")
        )
        await store.recordAttempt(canary)

        let raw = try Data(contentsOf: url)
        let text = String(decoding: raw, as: UTF8.self)
        XCTAssertFalse(text.contains("prompt-canary"))
        XCTAssertFalse(text.contains("response-canary"))
        XCTAssertFalse(text.contains("/Users/vj/private"))
        XCTAssertFalse(text.contains("command-canary"))
        XCTAssertFalse(text.contains("header-canary"))
        XCTAssertFalse(text.contains("provider-request-id"))
        XCTAssertFalse(text.contains("session-canary"))

        let decoded = try JSONDecoder.codex.decode(UsageTelemetryEnvelope.self, from: raw)
        XCTAssertEqual(decoded.schemaVersion, 1)
        XCTAssertEqual(decoded.events.count, 1)
        XCTAssertEqual(decoded.events[0].model, "other")
        XCTAssertEqual(decoded.events[0].provider, .other)
        XCTAssertEqual(decoded.events[0].taskBoardRunID, canary.taskBoardRunID)
    }

    func testDisabledStoreDoesNotCreateOrPersistEventsUntilEnabled() async throws {
        let (store, url, cleanup) = makeStore(enabled: false)
        defer { cleanup() }
        await store.recordAttempt(event())
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))

        await store.setEnabled(true)
        await store.recordAttempt(event())
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.events.count, 1)
    }

    func testDuplicateEventsAndRootTerminalsAreIdempotent() async throws {
        let (store, _, cleanup) = makeStore()
        defer { cleanup() }
        let root = UUID()
        let attempt = event(id: UUID(), root: root)
        await store.recordAttempt(attempt)
        await store.recordAttempt(attempt)
        let terminal = UsageTelemetryRootTerminal(
            rootRequestID: root,
            finishedAt: attempt.finishedAt,
            category: .interactive,
            outcome: .success,
            attemptCount: 1
        )
        await store.recordRootTerminal(terminal)
        await store.recordRootTerminal(terminal)

        let snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.events.count, 1)
        XCTAssertEqual(snapshot.lifetimeAttemptAggregates.reduce(0) { $0 + $1.attempts }, 1)
        XCTAssertEqual(snapshot.lifetimeRootAggregates.reduce(0) { $0 + $1.requests }, 1)
    }

    func testRetentionKeepsThirtyDayBoundaryAndDropsOlderEvents() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let (store, _, cleanup) = makeStore(now: now)
        defer { cleanup() }
        let boundary = now.addingTimeInterval(-30 * 86_400)
        await store.recordAttempt(event(id: UUID(), startedAt: boundary.addingTimeInterval(-1), finishedAt: boundary))
        await store.recordAttempt(event(id: UUID(), startedAt: boundary.addingTimeInterval(-1.001), finishedAt: boundary.addingTimeInterval(-0.001)))
        let snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.events.count, 1)
        XCTAssertEqual(snapshot.events.first?.finishedAt, boundary)
        XCTAssertEqual(snapshot.lifetimeAttemptAggregates.reduce(0) { $0 + $1.attempts }, 2)
    }

    func testEventCapDropsOldestAndReportsCoverageTruncation() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let (store, _, cleanup) = makeStore(now: now)
        defer { cleanup() }
        let events = (0...UsageTelemetryStore.maximumRetainedEvents).map { index in
            let instant = now.addingTimeInterval(-Double(index))
            return event(id: UUID(), startedAt: instant, finishedAt: instant)
        }
        await store.recordAttempts(events)
        let snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.events.count, UsageTelemetryStore.maximumRetainedEvents)
        XCTAssertTrue(snapshot.detailTruncated)
        XCTAssertNotNil(snapshot.detailCoverageStart)
    }

    func testDailyRetentionAndLifetimeAggregatesPersistBeyondDailyWindow() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let (store, _, cleanup) = makeStore(now: now)
        defer { cleanup() }
        let old = now.addingTimeInterval(-366 * 86_400)
        let recent = now.addingTimeInterval(-364 * 86_400)
        await store.recordAttempt(event(id: UUID(), startedAt: old, finishedAt: old))
        await store.recordAttempt(event(id: UUID(), startedAt: recent, finishedAt: recent))
        let snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.dailyAttemptAggregates.count, 1)
        XCTAssertEqual(snapshot.lifetimeAttemptAggregates.reduce(0) { $0 + $1.attempts }, 2)
    }

    func testRootRetryAndFallbackAttributionIsUnscopedAndScopedPurgeLeavesItIntact() async throws {
        let (store, _, cleanup) = makeStore()
        defer { cleanup() }
        let root = UUID()
        await store.recordAttempt(event(id: UUID(), root: root, account: accountID, attemptIndex: 0, outcome: .httpError, status: 429, error: .rateLimit))
        await store.recordAttempt(event(id: UUID(), root: root, account: otherAccountID, attemptIndex: 1, provider: .other, model: "unknown-model", outcome: .success))
        await store.recordRootTerminal(.init(rootRequestID: root, finishedAt: Date(timeIntervalSince1970: 1_700_000_000), category: .interactive, outcome: .success, attemptCount: 2, accountFallbackCount: 1, modelFallbackCount: 1))
        await store.purge(accountTelemetryID: accountID)

        let snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.lifetimeAttemptAggregates.reduce(0) { $0 + $1.attempts }, 1)
        XCTAssertEqual(snapshot.lifetimeRootAggregates.reduce(0) { $0 + $1.requests }, 1)
        XCTAssertEqual(snapshot.lifetimeRootAggregates.reduce(0) { $0 + $1.retries }, 1)
        XCTAssertEqual(snapshot.lifetimeRootAggregates.reduce(0) { $0 + $1.accountFallbacks }, 1)
    }

    func testClearRemovesEventsAndBothAggregateFamilies() async throws {
        let (store, url, cleanup) = makeStore()
        defer { cleanup() }
        let root = UUID()
        await store.recordAttempt(event(root: root))
        await store.recordRootTerminal(.init(rootRequestID: root, finishedAt: Date(timeIntervalSince1970: 1_700_000_000), category: .interactive, outcome: .success, attemptCount: 1))
        await store.clear()
        let snapshot = await store.snapshot()
        XCTAssertTrue(snapshot.events.isEmpty)
        XCTAssertTrue(snapshot.dailyAttemptAggregates.isEmpty)
        XCTAssertTrue(snapshot.lifetimeAttemptAggregates.isEmpty)
        XCTAssertTrue(snapshot.lifetimeRootAggregates.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testInvalidFutureDatesDurationsTokensAndStatusAreDiscarded() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let (store, _, cleanup) = makeStore(now: now)
        defer { cleanup() }
        await store.recordAttempt(event(startedAt: now, finishedAt: now.addingTimeInterval(1)))
        await store.recordAttempt(event(startedAt: now, finishedAt: now, duration: -1))
        await store.recordAttempt(event(startedAt: now, finishedAt: now, input: -1))
        await store.recordAttempt(event(startedAt: now, finishedAt: now, status: 42))
        await store.recordRootTerminal(.init(rootRequestID: UUID(), finishedAt: now.addingTimeInterval(1), category: .interactive, outcome: .success, attemptCount: 1))
        let snapshot = await store.snapshot()
        XCTAssertTrue(snapshot.events.isEmpty)
        XCTAssertTrue(snapshot.lifetimeAttemptAggregates.isEmpty)
        XCTAssertTrue(snapshot.lifetimeRootAggregates.isEmpty)
    }

    func testMissingTokensStayUnknownAndDoNotBecomeZeroOrComplete() async throws {
        let (store, _, cleanup) = makeStore()
        defer { cleanup() }
        await store.recordAttempt(event(input: nil, cached: nil, cacheWrite: nil, output: nil, reasoning: nil))
        let snapshot = await store.snapshot()
        let aggregate = try XCTUnwrap(snapshot.lifetimeAttemptAggregates.first)
        XCTAssertEqual(aggregate.inputTokens, 0)
        XCTAssertEqual(aggregate.inputTokensCompleteness, .unknown)
        XCTAssertEqual(aggregate.cachedInputTokensCompleteness, .unknown)
        XCTAssertEqual(aggregate.outputTokensCompleteness, .unknown)
    }

    func testSaturatingCountersAndExactLatencyBucketsWithNearestRankPercentiles() async throws {
        let (store, _, cleanup) = makeStore()
        defer { cleanup() }
        for (index, duration) in [0, 25, 600_000].enumerated() {
            await store.recordAttempt(event(id: UUID(), input: Int.max, cached: nil, cacheWrite: nil, output: nil, reasoning: nil, duration: duration))
            if index == 2 { break }
        }
        for _ in 0..<20 {
            await store.recordAttempt(event(id: UUID(), input: nil, cached: nil, cacheWrite: nil, output: nil, reasoning: nil, duration: 600_000))
        }
        let snapshot = await store.snapshot()
        let aggregate = try XCTUnwrap(snapshot.lifetimeAttemptAggregates.first(where: { $0.accountTelemetryID == accountID }))
        XCTAssertEqual(aggregate.latencyHistogram.count, UsageTelemetryLatencyHistogram.bucketCount)
        XCTAssertEqual(aggregate.latencyHistogram[0], 1)
        XCTAssertEqual(aggregate.latencyHistogram[1], 1)
        XCTAssertEqual(aggregate.latencyHistogram[24], 21)
        XCTAssertEqual(aggregate.latencyPercentile(0.5), 600_000)
        XCTAssertEqual(aggregate.latencyPercentile(0.95), 600_000)
        XCTAssertEqual(aggregate.inputTokens, Int.max)
    }

    func testCorruptFileRecoversWithoutLeakingData() async throws {
        let (store, url, cleanup) = makeStore()
        defer { cleanup() }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ definitely-not-json".utf8).write(to: url)
        await store.recordAttempt(event())
        let snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.events.count, 1)
        let decoded = try JSONDecoder.codex.decode(UsageTelemetryEnvelope.self, from: Data(contentsOf: url))
        XCTAssertEqual(decoded.schemaVersion, 1)
    }

    func testPersistenceUsesPrivateDirectoryAndFileModes() async throws {
        let (store, url, cleanup) = makeStore()
        defer { cleanup() }
        await store.recordAttempt(event())
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: url.deletingLastPathComponent().path)
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertEqual((fileAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testRangeSnapshotsPreserveStoredLocalDayKeyAndOffsetAcrossSevenThirtyAndLifetime() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let (store, _, cleanup) = makeStore(now: now)
        defer { cleanup() }
        let recent = event(id: UUID(), startedAt: now.addingTimeInterval(-2 * 86_400 - 1), finishedAt: now.addingTimeInterval(-2 * 86_400))
        let older = event(id: UUID(), startedAt: now.addingTimeInterval(-8 * 86_400 - 1), finishedAt: now.addingTimeInterval(-8 * 86_400))
        await store.recordAttempts([recent, older])

        let seven = await store.snapshot(range: .sevenDays)
        let thirty = await store.snapshot(range: .thirtyDays)
        let lifetime = await store.snapshot(range: .lifetime)
        XCTAssertEqual(seven.range, .sevenDays)
        XCTAssertEqual(thirty.range, .thirtyDays)
        XCTAssertNil(lifetime.rangeStart)
        XCTAssertEqual(seven.events.count, 1)
        XCTAssertEqual(thirty.events.count, 2)
        XCTAssertTrue(thirty.dailyAttemptAggregates.allSatisfy { $0.utcOffsetSeconds == TimeZone.current.secondsFromGMT(for: $0.dayStart) || $0.utcOffsetSeconds == 0 })
        XCTAssertEqual(lifetime.lifetimeAttemptAggregates.reduce(0) { $0 + $1.attempts }, 2)
    }
}
