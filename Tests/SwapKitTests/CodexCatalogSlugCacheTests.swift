import XCTest
import Foundation
@testable import SwapKit

final class CodexCatalogSlugCacheTests: XCTestCase {
    private struct LoadFailure: Error {}

    func testFirstFailureFailsClosedAndBacksOffForOneInterval() async {
        let clock = TestClock()
        let loader = ScriptedLoader([.failure(LoadFailure()), .failure(LoadFailure())])
        let cache = CodexCatalogSlugCache(now: clock.now, loader: loader.load)

        let first = await cache.slugs()
        let second = await cache.slugs()
        XCTAssertEqual(first, [])
        XCTAssertEqual(second, [])
        XCTAssertEqual(loader.calls, 1, "a failed launch must not be respawned on every request")

        clock.advance(61)
        _ = await cache.slugs()
        XCTAssertEqual(loader.calls, 2)
    }

    func testFailureAfterSuccessKeepsLastGoodSetUntilMaximumStaleness() async {
        let clock = TestClock()
        let loader = ScriptedLoader([
            .success(["gpt-6.1-sol"]),
            .failure(LoadFailure()),
            .failure(LoadFailure()),
        ])
        let cache = CodexCatalogSlugCache(now: clock.now, loader: loader.load)

        let initial = await cache.slugs()
        XCTAssertEqual(initial, ["gpt-6.1-sol"])
        clock.advance(61)
        let stale = await cache.slugs()
        XCTAssertEqual(stale, ["gpt-6.1-sol"], "a transient failure keeps the last good set")
        clock.advance(540)
        let expired = await cache.slugs()
        XCTAssertEqual(expired, [], "a set older than the staleness bound fails closed")
        XCTAssertEqual(loader.calls, 3)
    }

    func testCancelledLoadIsNotCached() async {
        let clock = TestClock()
        let loader = ScriptedLoader([.failure(CancellationError()), .success(["gpt-6.1-sol"])])
        let cache = CodexCatalogSlugCache(now: clock.now, loader: loader.load)

        let cancelled = await cache.slugs()
        let retried = await cache.slugs()
        XCTAssertEqual(cancelled, [])
        XCTAssertEqual(retried, ["gpt-6.1-sol"], "cancellation must not start the failure back-off")
        XCTAssertEqual(loader.calls, 2)
    }

    func testOverlappingCallersShareOneLoad() async {
        let release = Gate()
        let loader = ScriptedLoader([.success(["gpt-6.1-sol"])], release: release)
        let cache = CodexCatalogSlugCache(loader: loader.load)

        let callers = (0..<8).map { _ in Task { await cache.slugs() } }
        await loader.entered.wait()
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(loader.calls, 1, "callers overlapping an in-flight load must join it")

        await release.open()
        var results: [Set<String>] = []
        for caller in callers { results.append(await caller.value) }
        XCTAssertEqual(results, Array(repeating: ["gpt-6.1-sol"], count: 8))
        XCTAssertEqual(loader.calls, 1)
    }

    func testCancelledCreatorDoesNotAbortJoinedCallers() async {
        let release = Gate()
        let loader = ScriptedLoader([.success(["gpt-6.1-sol"])], release: release)
        let cache = CodexCatalogSlugCache(loader: loader.load)

        let creator = Task { await cache.slugs() }
        await loader.entered.wait()
        let joiner = Task { await cache.slugs() }
        try? await Task.sleep(for: .milliseconds(50))
        creator.cancel()
        await release.open()

        let joined = await joiner.value
        XCTAssertEqual(joined, ["gpt-6.1-sol"])
        XCTAssertEqual(loader.calls, 1)
        _ = await creator.value
    }

    func testPeekSuppressesDispatcherEntriesWhileDiscoveryRuns() async {
        let release = Gate()
        let loader = ScriptedLoader([.success(["gpt-6.1-sol"])], release: release)
        let cache = CodexCatalogSlugCache(loader: loader.load)

        let discovery = Task { await cache.slugs() }
        await loader.entered.wait()
        let during = await cache.peekSlugs()
        XCTAssertEqual(during, [], "discovery may read /models through the proxy and must see no dispatcher entries")

        await release.open()
        _ = await discovery.value
        let after = await cache.peekSlugs()
        XCTAssertEqual(after, ["gpt-6.1-sol"])
        XCTAssertEqual(loader.calls, 1)
    }

    func testPeekStartsOneBackgroundLoadAndNeverWaits() async throws {
        let release = Gate()
        let loader = ScriptedLoader([.success(["gpt-6.1-sol"])], release: release)
        let cache = CodexCatalogSlugCache(loader: loader.load)

        let cold = await cache.peekSlugs()
        XCTAssertEqual(cold, [], "peek returns while the load is still blocked")
        for _ in 0..<5 { _ = await cache.peekSlugs() }
        await loader.entered.wait()
        XCTAssertEqual(loader.calls, 1)

        await release.open()
        var warmed: Set<String> = []
        for _ in 0..<100 where warmed.isEmpty {
            try await Task.sleep(for: .milliseconds(20))
            warmed = await cache.peekSlugs()
        }
        XCTAssertEqual(warmed, ["gpt-6.1-sol"])
        XCTAssertEqual(loader.calls, 1)
    }
}

private actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_800_000_000)

    var now: @Sendable () -> Date {
        { [self] in lock.withLock { current } }
    }

    func advance(_ seconds: TimeInterval) {
        lock.withLock { current = current.addingTimeInterval(seconds) }
    }
}

private final class ScriptedLoader: @unchecked Sendable {
    let entered = Gate()
    private let lock = NSLock()
    private var script: [Result<Set<String>, Error>]
    private var count = 0
    private let release: Gate?

    init(_ script: [Result<Set<String>, Error>], release: Gate? = nil) {
        self.script = script
        self.release = release
    }

    var calls: Int { lock.withLock { count } }

    var load: CodexCatalogSlugCache.Loader {
        { [self] in
            let next: Result<Set<String>, Error> = lock.withLock {
                count += 1
                return script.isEmpty ? .failure(CancellationError()) : script.removeFirst()
            }
            await entered.open()
            if let release { await release.wait() }
            return try next.get()
        }
    }
}
