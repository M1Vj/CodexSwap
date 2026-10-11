import Foundation
import XCTest
@testable import SwapKit

private actor RenewalCalls {
    private(set) var homes: [URL] = []
    private(set) var forces: [Bool] = []
    private(set) var events: [String] = []

    func owner(_ home: URL) { homes.append(home); events.append("renew") }
    func standalone(force: Bool) { forces.append(force); events.append("renew") }
    func fetched() { events.append("fetch") }
}

private actor RenewalGate {
    private var entered = false
    private var joined = 0
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var released = false

    func hold() async {
        entered = true
        guard !released else { return }
        await withCheckedContinuation { releaseContinuation = $0 }
    }

    func join() { joined += 1 }
    func ready(joiners: Int = 0) -> Bool { entered && joined >= joiners }
    func release() { released = true; releaseContinuation?.resume(); releaseContinuation = nil }
}

private final class RenewalClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date()
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ seconds: TimeInterval) { lock.lock(); value.addTimeInterval(seconds); lock.unlock() }
}

private actor RenewalUsageStub: UsageFetching {
    private let outcomes: [Result<[UsageWindow], UsageClient.UsageError>]
    private let calls: RenewalCalls
    private(set) var tokens: [String] = []
    private(set) var accountIDs: [String] = []

    init(_ outcomes: [Result<[UsageWindow], UsageClient.UsageError>], calls: RenewalCalls) {
        self.outcomes = outcomes
        self.calls = calls
    }

    func fetch(accessToken: String, accountID: String) async throws -> [UsageWindow] {
        let index = tokens.count
        tokens.append(accessToken)
        accountIDs.append(accountID)
        await calls.fetched()
        return try outcomes[min(index, outcomes.count - 1)].get()
    }
}

final class CredentialRenewalCoordinatorTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let home: URL
        let authURL: URL
        let store: AccountStore
        let account: Account
    }

    private var roots: [URL] = []

    override func tearDown() {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots.removeAll()
        super.tearDown()
    }

    func testHealthyAccountProactiveTickDoesNotRefreshOrLaunchCLI() async throws {
        let fixture = try await fixture(expiry: Date().addingTimeInterval(3 * 86_400))
        let calls = RenewalCalls()
        let coordinator = CredentialRenewalCoordinator(store: fixture.store, standaloneRenew: { _, force, _, _ in
            await calls.standalone(force: force)
            return .unavailable
        }, ownerRefresh: { home in
            await calls.owner(home)
            return false
        })
        let engine = await engine(fixture, coordinator: coordinator)

        await engine.proactiveCredentialRenewalTick()

        let events = await calls.events
        XCTAssertTrue(events.isEmpty)
    }

    func testManagedProactiveTickUsesOwnerHomeAndAdoptsOwnerTokens() async throws {
        let fixture = try await fixture(expiry: Date().addingTimeInterval(20 * 3_600))
        let fresh = tokens("owner-new", expiry: Date().addingTimeInterval(3 * 86_400))
        let calls = RenewalCalls()
        let authURL = fixture.authURL
        let coordinator = CredentialRenewalCoordinator(store: fixture.store, standaloneRenew: { _, _, _, _ in
            XCTFail("CodexSwap must not redeem a managed refresh token")
            return .unavailable
        }, ownerRefresh: { home in
            await calls.owner(home)
            try? CodexAuth.write(fresh, to: authURL)
            return true
        })
        let engine = await engine(fixture, coordinator: coordinator)

        await engine.proactiveCredentialRenewalTick()

        let homes = await calls.homes
        let stored = await fixture.store.account("managed")
        XCTAssertEqual(homes.map { $0.standardizedFileURL.path }, [fixture.home.standardizedFileURL.path])
        XCTAssertEqual(stored?.tokens, fresh)
        XCTAssertFalse(stored?.needsLogin ?? true)
        XCTAssertEqual(try CodexAuth.read(authURL).tokens, fresh)
    }

    func testNativeRenewalUsesContainingHomeAndAdoptsOwnerTokens() async throws {
        let fixture = try await fixture(expiry: Date().addingTimeInterval(-60), native: true)
        let fresh = tokens("native-new", expiry: Date().addingTimeInterval(86_400))
        let calls = RenewalCalls()
        let coordinator = coordinator(fixture, calls: calls, ownerTokens: fresh)

        let result = await coordinator.renew(fixture.account)

        guard case .renewed(let renewed) = result else { return XCTFail("expected owner refresh") }
        let homes = await calls.homes
        XCTAssertEqual(homes.map { $0.standardizedFileURL.path }, [fixture.home.standardizedFileURL.path])
        XCTAssertEqual(renewed.tokens, fresh)
    }

    func testOwnerFailureLeavesSourceAndNeedsLoginUnchanged() async throws {
        let fixture = try await fixture(expiry: Date().addingTimeInterval(-60))
        let before = try Data(contentsOf: fixture.authURL)
        let coordinator = coordinator(fixture, calls: RenewalCalls(), succeeds: false)

        let result = await coordinator.renew(fixture.account)

        XCTAssertEqual(result, .unavailable)
        XCTAssertEqual(try Data(contentsOf: fixture.authURL), before)
        let stored = await fixture.store.account("managed")
        XCTAssertFalse(stored?.needsLogin ?? true)
        XCTAssertEqual(stored?.tokens, fixture.account.tokens)
    }

    func testOwnerSuccessWithStillExpiredSourceIsUnavailable() async throws {
        let fixture = try await fixture(expiry: Date().addingTimeInterval(-60))
        let before = try Data(contentsOf: fixture.authURL)
        let coordinator = coordinator(fixture, calls: RenewalCalls())

        let result = await coordinator.renew(fixture.account)

        XCTAssertEqual(result, .unavailable)
        XCTAssertEqual(try Data(contentsOf: fixture.authURL), before)
        let stored = await fixture.store.account("managed")
        XCTAssertFalse(stored?.needsLogin ?? true)
    }

    func testRenewalFailureDuringPollingSkipsFetchAndDoesNotQuarantine() async throws {
        let fixture = try await fixture(expiry: Date().addingTimeInterval(-60), usage: [window(resetAt: Date().addingTimeInterval(-120))])
        let calls = RenewalCalls()
        let usage = RenewalUsageStub([.success([])], calls: calls)
        let engine = await engine(fixture, coordinator: coordinator(fixture, calls: calls, succeeds: false), usage: usage)

        await engine.pollUsage(activeOnly: false)

        let fetched = await usage.tokens
        let stored = await fixture.store.account("managed")
        XCTAssertTrue(fetched.isEmpty)
        XCTAssertEqual(stored?.usage, fixture.account.usage)
        XCTAssertFalse(stored?.needsLogin ?? true)
        let homes = await calls.homes
        XCTAssertEqual(homes.count, 1)
    }

    func testMissingExpiryProactiveTickRequestsOwnerRenewal() async throws {
        let fixture = try await fixture(expiry: Date().addingTimeInterval(-60))
        await fixture.store.updateTokens("managed", tokens: CodexTokens(idToken: "fixture-id", accessToken: "fixture-without-exp", refreshToken: "fixture-refresh", accountId: fixture.account.accountID))
        let calls = RenewalCalls()
        let engine = await engine(fixture, coordinator: coordinator(fixture, calls: calls, succeeds: false))

        await engine.proactiveCredentialRenewalTick()

        let homes = await calls.homes
        XCTAssertEqual(homes.map { $0.standardizedFileURL.path }, [fixture.home.standardizedFileURL.path])
    }

    func testNativeForcedRenewalAdoptsRotatedBundleWithLaterExpiry() async throws {
        let fixture = try await fixture(expiry: Date().addingTimeInterval(86_400), native: true)
        let fresh = tokens("native-rotated", expiry: Date().addingTimeInterval(864_000))
        let coordinator = coordinator(fixture, calls: RenewalCalls(), ownerTokens: fresh)

        let result = await coordinator.renew(fixture.account, force: true)

        guard case .renewed(let renewed) = result else { return XCTFail("expected the owner's rotated bundle") }
        XCTAssertEqual(renewed.tokens, fresh)
    }

    func testNativeForcedRenewalRejectsChangedBundleWithEqualExpiry() async throws {
        let expiry = Date().addingTimeInterval(86_400)
        let fixture = try await fixture(expiry: expiry, native: true)
        let coordinator = coordinator(fixture, calls: RenewalCalls(), ownerTokens: tokens("native-equal-expiry", expiry: expiry))

        let result = await coordinator.renew(fixture.account, force: true)

        XCTAssertEqual(result, .unavailable, "native hydration keeps rejecting a changed bundle that does not extend expiry")
    }

    func testThreeConcurrentRenewalsShareOneOwnerAttempt() async throws {
        let fixture = try await fixture(expiry: Date().addingTimeInterval(-60))
        let calls = RenewalCalls()
        let fresh = tokens("shared", expiry: Date().addingTimeInterval(86_400))
        let gate = RenewalGate()
        let authURL = fixture.authURL
        let coordinator = CredentialRenewalCoordinator(store: fixture.store, standaloneRenew: { _, _, _, _ in
            XCTFail("managed must not use standalone renewal")
            return .unavailable
        }, ownerRefresh: { home in
            await calls.owner(home)
            await gate.hold()
            try? CodexAuth.write(fresh, to: authURL)
            return true
        }, onJoinedFlight: { await gate.join() })

        async let first = coordinator.renew(fixture.account, force: true)
        async let second = coordinator.renew(fixture.account, force: true)
        async let third = coordinator.renew(fixture.account, force: true)
        try await waitForGate(gate, joiners: 2)
        await gate.release()
        let results = await [first, second, third]

        let homes = await calls.homes
        XCTAssertEqual(homes.count, 1)
        XCTAssertEqual(results[0], results[1])
        XCTAssertEqual(results[1], results[2])
        guard case .renewed(let renewed) = results[0] else { return XCTFail("expected shared renewal") }
        XCTAssertEqual(renewed.tokens, fresh)
    }

    func testFailureCooldownIsSharedAcrossTicksPollingAndForcedRecovery() async throws {
        let fixture = try await fixture(expiry: Date().addingTimeInterval(-60))
        let calls = RenewalCalls()
        let clock = RenewalClock()
        let coordinator = CredentialRenewalCoordinator(store: fixture.store, standaloneRenew: { _, _, _, _ in .unavailable }, ownerRefresh: { home in
            await calls.owner(home)
            return false
        }, clock: { clock.now() })
        let engine = await engine(fixture, coordinator: coordinator)
        await engine.proactiveCredentialRenewalTick()
        let firstTickAttempts = await calls.homes
        XCTAssertEqual(firstTickAttempts.count, 1)
        let cooldownCount = await coordinator.failureCooldownCount
        XCTAssertEqual(cooldownCount, 1)
        await engine.proactiveCredentialRenewalTick()
        await engine.pollUsage(activeOnly: false)
        await fixture.store.markNeedsLoginOnly(fixture.account.alias)
        await engine.recoverBlockedAuthentication()
        let forced = await coordinator.renew(fixture.account, force: true)
        XCTAssertEqual(forced, .unavailable)
        var homes = await calls.homes
        XCTAssertEqual(homes.count, 1)
        clock.advance(1_799)
        _ = await coordinator.renew(fixture.account, force: true)
        homes = await calls.homes
        XCTAssertEqual(homes.count, 1)
        clock.advance(1)
        _ = await coordinator.renew(fixture.account, force: true)
        homes = await calls.homes
        XCTAssertEqual(homes.count, 2)
        clock.advance(1_800)
        _ = await coordinator.renew(fixture.account, force: true)
        homes = await calls.homes
        XCTAssertEqual(homes.count, 2, "second failure doubles the cooldown")
        clock.advance(1_800)
        _ = await coordinator.renew(fixture.account, force: true)
        homes = await calls.homes
        XCTAssertEqual(homes.count, 3)
    }

    func testInvalidatedCooldownDoublesAndCapsAtSixHours() async throws {
        let fixture = try await fixture(expiry: Date().addingTimeInterval(-60))
        var account = fixture.account
        account.managedHomePath = nil
        account.credentialSource = AccountCredentialSource(kind: .standaloneHome, path: fixture.authURL.path)
        let calls = RenewalCalls()
        let clock = RenewalClock()
        let coordinator = CredentialRenewalCoordinator(store: fixture.store, standaloneRenew: { _, force, _, _ in
            await calls.standalone(force: force)
            return .invalidated
        }, ownerRefresh: { _ in XCTFail("standalone must not use owner"); return false }, clock: { clock.now() })
        for (index, duration) in [1_800.0, 3_600, 7_200, 14_400, 21_600, 21_600].enumerated() {
            let failure = await coordinator.renew(account, force: true)
            XCTAssertEqual(failure, .invalidated)
            clock.advance(duration - 1)
            let cached = await coordinator.renew(account, force: true)
            XCTAssertEqual(cached, .invalidated)
            let attempts = await calls.forces
            XCTAssertEqual(attempts.count, index + 1)
            clock.advance(1)
        }
        _ = await coordinator.renew(account, force: true)
        let attempts = await calls.forces
        XCTAssertEqual(attempts.count, 7)
    }

    func testChangedSourceClearsFailureCooldownImmediately() async throws {
        let fixture = try await fixture(expiry: Date().addingTimeInterval(-60))
        let calls = RenewalCalls()
        let coordinator = coordinator(fixture, calls: calls, succeeds: false)
        _ = await coordinator.renew(fixture.account, force: true)
        let attributes = try FileManager.default.attributesOfItem(atPath: fixture.authURL.path)
        try CodexAuth.write(tokens("re-login", expiry: Date().addingTimeInterval(86_400)), to: fixture.authURL)
        // A contents change must also work when the timestamp is unchanged.
        try FileManager.default.setAttributes([.modificationDate: try XCTUnwrap(attributes[.modificationDate])], ofItemAtPath: fixture.authURL.path)
        _ = await coordinator.renew(fixture.account, force: true)
        let homes = await calls.homes
        XCTAssertEqual(homes.count, 2)
    }

    func testSuccessResetsConsecutiveFailureCooldown() async throws {
        let fixture = try await fixture(expiry: Date().addingTimeInterval(-60))
        let calls = RenewalCalls()
        let clock = RenewalClock()
        let authURL = fixture.authURL
        let fresh = tokens("cooldown-success", expiry: Date().addingTimeInterval(86_400))
        let coordinator = CredentialRenewalCoordinator(store: fixture.store, standaloneRenew: { _, _, _, _ in .unavailable }, ownerRefresh: { home in
            await calls.owner(home)
            if await calls.homes.count == 2 {
                try? CodexAuth.write(fresh, to: authURL)
                return true
            }
            return false
        }, clock: { clock.now() })
        _ = await coordinator.renew(fixture.account, force: true)
        clock.advance(1_800)
        let success = await coordinator.renew(fixture.account, force: true)
        guard case .renewed(let account) = success else { return XCTFail("expected success") }
        _ = await coordinator.renew(account, force: true)
        clock.advance(1_800)
        _ = await coordinator.renew(account, force: true)
        let homes = await calls.homes
        XCTAssertEqual(homes.count, 4, "success restores the first-failure cooldown")
    }

    func testCloseAdmissionPreservesInFlightOwnerAdoptionAndRejectsLaterRenewals() async throws {
        let fixture = try await fixture(expiry: Date().addingTimeInterval(-60))
        let gate = RenewalGate()
        let calls = RenewalCalls()
        let authURL = fixture.authURL
        let fresh = tokens("rotated-owner", expiry: Date().addingTimeInterval(86_400))
        let coordinator = CredentialRenewalCoordinator(store: fixture.store, standaloneRenew: { _, _, _, _ in
            XCTFail("managed renewal must not launch standalone work")
            return .unavailable
        }, ownerRefresh: { home in
            await calls.owner(home)
            if await calls.homes.count == 1 { await gate.hold() }
            try? CodexAuth.write(fresh, to: authURL)
            return true
        })
        let task = Task { await coordinator.renew(fixture.account, force: true) }
        try await waitForGate(gate)
        await coordinator.closeAdmission()
        let rejected = await coordinator.renew(fixture.account, force: true)
        XCTAssertEqual(rejected, .unavailable)
        let cooldownsWhileInFlight = await coordinator.failureCooldownCount
        XCTAssertEqual(cooldownsWhileInFlight, 0)
        await gate.release()
        let result = await task.value
        guard case .renewed(let renewed) = result else { return XCTFail("in-flight owner rotation must be adopted") }
        XCTAssertEqual(renewed.tokens, fresh)
        let stored = await fixture.store.account(fixture.account.alias)
        XCTAssertEqual(stored?.tokens, fresh)
        let attempts = await calls.homes
        XCTAssertEqual(attempts.count, 1)
        let retry = await coordinator.renew(renewed, force: true)
        XCTAssertEqual(retry, .unavailable)
        let finalAttempts = await calls.homes
        XCTAssertEqual(finalAttempts.count, 1)
        let cooldownsAfterCompletion = await coordinator.failureCooldownCount
        XCTAssertEqual(cooldownsAfterCompletion, 0)
    }

    func testClosedAdmissionLaunchesNothingAndRecordsNoFailureCooldown() async throws {
        let fixture = try await fixture(expiry: Date().addingTimeInterval(-60))
        let calls = RenewalCalls()
        let coordinator = CredentialRenewalCoordinator(store: fixture.store, standaloneRenew: { _, force, _, _ in
            await calls.standalone(force: force)
            return .invalidated
        }, ownerRefresh: { home in
            await calls.owner(home)
            return false
        })
        await coordinator.closeAdmission()
        await coordinator.closeAdmission()
        let owner = await coordinator.renew(fixture.account, force: true)
        var standalone = fixture.account
        standalone.managedHomePath = nil
        standalone.credentialSource = AccountCredentialSource(kind: .standaloneHome, path: fixture.authURL.path)
        let owned = await coordinator.renew(standalone, force: true)
        var nonRenewable = fixture.account
        nonRenewable.managedHomePath = nil
        nonRenewable.credentialSource = AccountCredentialSource(kind: .legacySnapshot, path: fixture.authURL.path)
        let legacy = await coordinator.renew(nonRenewable)
        let events = await calls.events
        let cooldownCount = await coordinator.failureCooldownCount
        XCTAssertEqual(owner, .unavailable)
        XCTAssertEqual(owned, .unavailable)
        XCTAssertEqual(legacy, .unavailable)
        XCTAssertTrue(events.isEmpty)
        XCTAssertEqual(cooldownCount, 0)
    }

    func testCancellingJoinedWaiterDoesNotCancelSharedFlight() async throws {
        let fixture = try await fixture(expiry: Date().addingTimeInterval(-60))
        let gate = RenewalGate()
        let fresh = tokens("joined", expiry: Date().addingTimeInterval(86_400))
        let authURL = fixture.authURL
        let coordinator = CredentialRenewalCoordinator(store: fixture.store, standaloneRenew: { _, _, _, _ in .unavailable }, ownerRefresh: { _ in
            await gate.hold()
            try? CodexAuth.write(fresh, to: authURL)
            return true
        }, onJoinedFlight: { await gate.join() })
        let first = Task { await coordinator.renew(fixture.account, force: true) }
        try await waitForGate(gate)
        let joined = Task { await coordinator.renew(fixture.account, force: true) }
        try await waitForGate(gate, joiners: 1)
        joined.cancel()
        await gate.release()
        let result = await first.value
        guard case .renewed = result else { return XCTFail("waiter cancellation must not cancel the flight") }
        let joinedResult = await joined.value
        XCTAssertEqual(joinedResult, result)
    }

    func testNonRenewableSourcesReturnNotRenewableBeforeExpiryGuard() async throws {
        let fixture = try await fixture(expiry: Date().addingTimeInterval(86_400))
        let calls = RenewalCalls()
        let coordinator = coordinator(fixture, calls: calls)
        for kind: AccountCredentialSource.Kind in [.legacySnapshot, .unknown] {
            var account = fixture.account
            account.managedHomePath = nil
            account.credentialSource = AccountCredentialSource(kind: kind, path: fixture.authURL.path)
            let result = await coordinator.renew(account)
            XCTAssertEqual(result, .notRenewable)
        }
        let homes = await calls.homes
        XCTAssertTrue(homes.isEmpty)
    }

    func testCancelledJoinedPeerAdoptsOwnerTokensUsingAccountIDFallback() async throws {
        let fixture = try await fixture(expiry: Date().addingTimeInterval(-60), native: true)
        var first = fixture.account
        first.userID = "first-fixture-user"
        await fixture.store.upsert(first)
        var peer = fixture.account
        peer.alias = "peer"
        peer.userID = "peer-fixture-user"
        peer.credentialAccountID = nil
        await fixture.store.upsert(peer)
        let current = await fixture.store.account(peer.alias)
        XCTAssertNil(current?.credentialAccountID)
        let fresh = tokens("identity-fallback", expiry: Date().addingTimeInterval(86_400))
        let authURL = fixture.authURL
        let gate = RenewalGate()
        let calls = RenewalCalls()
        let coordinator = CredentialRenewalCoordinator(store: fixture.store, standaloneRenew: { _, _, _, _ in .unavailable }, ownerRefresh: { home in
            await calls.owner(home)
            await gate.hold()
            try? CodexAuth.write(fresh, to: authURL)
            return true
        }, onJoinedFlight: { await gate.join() })
        let firstAccount = first
        let peerAccount = peer
        let attempt = Task { await coordinator.renew(firstAccount, force: true) }
        try await waitForGate(gate)
        let joined = Task { await coordinator.renew(peerAccount, force: true) }
        try await waitForGate(gate, joiners: 1)
        joined.cancel()
        await gate.release()
        let result = await joined.value
        _ = await attempt.value
        guard case .renewed(let adopted) = result else { return XCTFail("expected fallback identity adoption") }
        XCTAssertEqual(adopted.alias, peer.alias)
        XCTAssertEqual(adopted.tokens, fresh)
        let homes = await calls.homes
        XCTAssertEqual(homes.count, 1)
    }

    func testAppEngineStopDuringProactiveTickPreservesAAndNeverStartsB() async throws {
        try await assertStopPreservesStartedRenewal(polling: false)
    }

    func testAppEngineStopDuringPollingPreservesAAndNeverStartsB() async throws {
        try await assertStopPreservesStartedRenewal(polling: true)
    }

    func testCancelledPollStopsBetweenAccountsWithoutClosingAdmission() async throws {
        try await assertStopPreservesStartedRenewal(polling: true, stopEngine: false)
    }

    private func assertStopPreservesStartedRenewal(polling: Bool, stopEngine: Bool = true) async throws {
        let fixture = try await fixture(expiry: Date().addingTimeInterval(-60))
        let secondHome = fixture.root.appendingPathComponent("second-home")
        try FileManager.default.createDirectory(at: secondHome, withIntermediateDirectories: true)
        let secondAuthURL = secondHome.appendingPathComponent("auth.json")
        let secondTokens = tokens("B", expiry: Date().addingTimeInterval(stopEngine ? -60 : 86_400), accountID: "second-id")
        try CodexAuth.write(secondTokens, to: secondAuthURL)
        let second = Account(alias: "second", accountID: secondTokens.accountId,
                             accessToken: secondTokens.accessToken, refreshToken: secondTokens.refreshToken,
                             idToken: secondTokens.idToken, managedHomePath: secondHome.path,
                             credentialSource: AccountCredentialSource(kind: .managedHome, path: secondHome.path))
        await fixture.store.upsert(second)
        let ordered = await fixture.store.activeAccounts()
        XCTAssertEqual(ordered.map(\.alias), [fixture.account.alias, second.alias])
        let gate = RenewalGate()
        let calls = RenewalCalls()
        let fresh = tokens("stopped", expiry: Date().addingTimeInterval(86_400))
        let authURL = fixture.authURL
        let coordinator = CredentialRenewalCoordinator(store: fixture.store, standaloneRenew: { _, _, _, _ in .unavailable }, ownerRefresh: { home in
            await calls.owner(home)
            guard home.standardizedFileURL == fixture.home.standardizedFileURL else {
                XCTFail("B's renewal must never start after stop")
                return false
            }
            await gate.hold()
            XCTAssertFalse(Task.isCancelled, "the started owner refresh must not be cancelled")
            try? CodexAuth.write(fresh, to: authURL)
            return true
        })
        let usage = RenewalUsageStub([.success([])], calls: calls)
        let engine = await engine(fixture, coordinator: coordinator, usage: usage)
        let task = Task {
            if polling { _ = await engine.pollUsage(activeOnly: false) }
            else { await engine.proactiveCredentialRenewalTick() }
        }
        try await waitForGate(gate)
        if stopEngine { await engine.stop() }
        else { task.cancel() }
        await gate.release()
        await task.value
        if !stopEngine { await engine.stop() }
        let stored = await fixture.store.account(fixture.account.alias)
        XCTAssertEqual(stored?.tokens, fresh)
        let secondStored = await fixture.store.account(second.alias)
        XCTAssertEqual(secondStored?.tokens, secondTokens)
        let homes = await calls.homes
        XCTAssertEqual(homes.map { $0.standardizedFileURL.path }, [fixture.home.standardizedFileURL.path])
        let fetchedIDs = await usage.accountIDs
        XCTAssertFalse(fetchedIDs.contains(second.accountID))
    }

    private func waitForGate(_ gate: RenewalGate, joiners: Int = 0) async throws {
        let deadline = Date().addingTimeInterval(2)
        while !(await gate.ready(joiners: joiners)), Date() < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        let ready = await gate.ready(joiners: joiners)
        if !ready { await gate.release() }
        XCTAssertTrue(ready, "renewal did not reach the explicit gate")
    }

    func testStaleUsageRenewsBeforeFetchAndReplacesElapsedWindow() async throws {
        let now = Date()
        let fixture = try await fixture(expiry: now.addingTimeInterval(-60), usage: [window(resetAt: now.addingTimeInterval(-120))])
        let calls = RenewalCalls()
        let fresh = tokens("polled", expiry: now.addingTimeInterval(86_400))
        let reading = [window(percent: 2, resetAt: now.addingTimeInterval(18_000))]
        let usage = RenewalUsageStub([.success(reading)], calls: calls)
        let coordinator = coordinator(fixture, calls: calls, ownerTokens: fresh)
        let engine = await engine(fixture, coordinator: coordinator, usage: usage)

        await engine.pollUsage(activeOnly: false, now: now)

        let events = await calls.events
        let fetched = await usage.tokens
        let stored = await fixture.store.account("managed")
        XCTAssertEqual(events, ["renew", "fetch"])
        XCTAssertEqual(fetched, [fresh.accessToken])
        XCTAssertEqual(stored?.usage, reading)
        XCTAssertFalse(stored?.needsLogin ?? true)
    }

    func testUsageUnauthorizedForcesRenewalAndRetriesExactlyOnce() async throws {
        try await assertUnauthorizedRetry(retrySucceeds: true)
    }

    func testUsageRepeatedUnauthorizedKeepsOldReadingWithoutNeedsLogin() async throws {
        try await assertUnauthorizedRetry(retrySucceeds: false)
    }

    func testInactiveElapsedWindowPollIsThrottledForFiveMinutes() async throws {
        let now = Date()
        let fixture = try await fixture(expiry: now.addingTimeInterval(-60), usage: [window(resetAt: now.addingTimeInterval(-120))])
        let activeTokens = tokens("active", expiry: now.addingTimeInterval(3 * 86_400), accountID: "active-id")
        await fixture.store.upsert(Account(alias: "active", accountID: "active-id", accessToken: activeTokens.accessToken))
        _ = await fixture.store.setActive("active")
        let calls = RenewalCalls()
        let fresh = tokens("inactive", expiry: now.addingTimeInterval(86_400))
        let usage = RenewalUsageStub([.failure(.http(503))], calls: calls)
        let coordinator = coordinator(fixture, calls: calls, ownerTokens: fresh)
        let engine = await engine(fixture, coordinator: coordinator, usage: usage)

        await engine.pollUsage(activeOnly: true, now: now)
        await engine.pollUsage(activeOnly: true, now: now.addingTimeInterval(299))
        let firstIDs = await usage.accountIDs
        XCTAssertEqual(firstIDs.filter { $0 == fixture.account.accountID }.count, 1)
        await engine.pollUsage(activeOnly: true, now: now.addingTimeInterval(300))
        let finalIDs = await usage.accountIDs
        let homes = await calls.homes
        XCTAssertEqual(finalIDs.filter { $0 == fixture.account.accountID }.count, 2)
        XCTAssertEqual(homes.count, 1)
    }

    func testUsageMergeDropsElapsedUnreportedWindowAndKeepsFutureWindow() async throws {
        let now = Date()
        let elapsed = window(resetAt: now.addingTimeInterval(-120))
        let future = UsageWindow(label: "daily", usedPercent: 25, windowSeconds: 86_400, resetAt: now.addingTimeInterval(3_600))
        let weekly = UsageWindow(label: "Weekly", usedPercent: 40, windowSeconds: 604_800, resetAt: now.addingTimeInterval(86_400))
        let fixture = try await fixture(expiry: now.addingTimeInterval(86_400), usage: [elapsed, future, weekly])
        let updatedWeekly = UsageWindow(label: "Weekly", usedPercent: 41, windowSeconds: 604_800, resetAt: weekly.resetAt)

        await fixture.store.updateUsage("managed", windows: [updatedWeekly])

        let stored = await fixture.store.account("managed")
        XCTAssertEqual(stored?.usage, [future, updatedWeekly])
    }

    func testBlockedManagedRecoveryRefreshesOwnerBeforeVerifiedSourceRecovery() async throws {
        let fixture = try await fixture(expiry: Date().addingTimeInterval(-60), needsLogin: true)
        let calls = RenewalCalls()
        let fresh = tokens("recovered", expiry: Date().addingTimeInterval(86_400))
        let usage = RenewalUsageStub([.success([window(percent: 1, resetAt: nil)])], calls: calls)
        let engine = await engine(fixture, coordinator: coordinator(fixture, calls: calls, ownerTokens: fresh), usage: usage)

        await engine.recoverBlockedAuthentication()

        let events = await calls.events
        let stored = await fixture.store.account("managed")
        XCTAssertEqual(events, ["renew", "fetch"])
        XCTAssertFalse(stored?.needsLogin ?? true)
        XCTAssertEqual(stored?.tokens, fresh)
    }

    func testProactiveTickSkipsArchivedAndRoutingDisabledAccounts() async throws {
        let fixture = try await fixture(expiry: Date().addingTimeInterval(-60))
        await fixture.store.setRoutingEnabled("managed", enabled: false)
        var archived = fixture.account
        archived.alias = "archived"
        archived.accountID = "archived-id"
        archived.archivedAt = Date()
        archived.credentialSource = nil
        archived.managedHomePath = nil
        await fixture.store.upsert(archived)
        let calls = RenewalCalls()
        let engine = await engine(fixture, coordinator: coordinator(fixture, calls: calls))

        await engine.proactiveCredentialRenewalTick()

        let homes = await calls.homes
        XCTAssertTrue(homes.isEmpty)
    }

    private func assertUnauthorizedRetry(retrySucceeds: Bool) async throws {
        let oldReading = [window(resetAt: Date().addingTimeInterval(3_600))]
        let fixture = try await fixture(expiry: Date().addingTimeInterval(86_400), usage: oldReading)
        let fresh = tokens("retry", expiry: Date().addingTimeInterval(3 * 86_400))
        let calls = RenewalCalls()
        var standalone = fixture.account
        standalone.managedHomePath = nil
        standalone.credentialSource = AccountCredentialSource(kind: .standaloneHome, path: fixture.authURL.path)
        await fixture.store.remove("managed")
        await fixture.store.upsert(standalone)
        let coordinator = CredentialRenewalCoordinator(store: fixture.store, standaloneRenew: { account, force, _, _ in
            await calls.standalone(force: force)
            var renewed = account
            renewed.accessToken = fresh.accessToken
            return .renewed(renewed)
        }, ownerRefresh: { _ in XCTFail("standalone must not use CLI"); return false })
        let freshReading = [window(percent: 3, resetAt: Date().addingTimeInterval(18_000))]
        let usage = RenewalUsageStub([.failure(.unauthorized), retrySucceeds ? .success(freshReading) : .failure(.unauthorized)], calls: calls)
        let engine = await engine(fixture, coordinator: coordinator, usage: usage)

        await engine.pollUsage(activeOnly: false)

        let forces = await calls.forces
        let fetched = await usage.tokens
        let stored = await fixture.store.account("managed")
        XCTAssertEqual(forces, [true])
        XCTAssertEqual(fetched, [standalone.accessToken, fresh.accessToken])
        XCTAssertEqual(stored?.usage, retrySucceeds ? freshReading : oldReading)
        XCTAssertFalse(stored?.needsLogin ?? true)
    }

    private func fixture(expiry: Date, native: Bool = false, usage: [UsageWindow] = [], needsLogin: Bool = false) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("credential-renewal-\(UUID().uuidString)")
        roots.append(root)
        let home = root.appendingPathComponent("owner-home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let authURL = home.appendingPathComponent("auth.json")
        let original = tokens("old", expiry: expiry)
        try CodexAuth.write(original, to: authURL)
        let account = Account(alias: "managed", accountID: original.accountId, accessToken: original.accessToken,
                              refreshToken: original.refreshToken, idToken: original.idToken, needsLogin: needsLogin,
                              usage: usage, managedHomePath: native ? nil : home.path,
                              credentialSource: AccountCredentialSource(kind: native ? .nativeAuth : .managedHome, path: native ? authURL.path : home.path))
        let store = AccountStore(url: root.appendingPathComponent("accounts.json"), ambientNativeAccountProvider: { nil })
        await store.upsert(account)
        return Fixture(root: root, home: home, authURL: authURL, store: store, account: account)
    }

    private func coordinator(_ fixture: Fixture, calls: RenewalCalls, ownerTokens: CodexTokens? = nil, succeeds: Bool = true, delay: UInt64 = 0) -> CredentialRenewalCoordinator {
        let authURL = fixture.authURL
        return CredentialRenewalCoordinator(store: fixture.store, standaloneRenew: { _, _, _, _ in
            XCTFail("managed/native must never invoke OAuth renewal")
            return .unavailable
        }, ownerRefresh: { home in
            await calls.owner(home)
            if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
            if let ownerTokens { try? CodexAuth.write(ownerTokens, to: authURL) }
            return succeeds
        })
    }

    private func engine(_ fixture: Fixture, coordinator: CredentialRenewalCoordinator, usage: (any UsageFetching)? = nil) async -> AppEngine {
        let settings = SettingsStore(url: fixture.root.appendingPathComponent("settings.json"))
        _ = await settings.update { $0.smartSwitchEnabled = false; $0.automaticallyWarmAccounts = false }
        return AppEngine(
            store: fixture.store,
            settingsStore: settings,
            usage: usage ?? RenewalUsageStub([.success([])], calls: RenewalCalls()),
            configManager: CodexConfigManager(codexHome: fixture.home, supportDir: fixture.root),
            warmupService: QuotaWarmupService(ledger: WarmupLedgerStore(url: fixture.root.appendingPathComponent("warmup.json")), lockURL: fixture.root.appendingPathComponent("warmup.lock")),
            taskStore: TaskStore(url: fixture.root.appendingPathComponent("tasks.json")),
            taskRunning: TaskRunner(),
            autoLog: AutomationLog(url: fixture.root.appendingPathComponent("automation.log")),
            supportDir: fixture.root,
            networkCheck: { true },
            credentialRenewalCoordinator: coordinator
        )
    }

    private func window(percent: Int = 100, resetAt: Date?) -> UsageWindow {
        UsageWindow(label: "5h", usedPercent: percent, windowSeconds: 18_000, resetAt: resetAt)
    }

    private func tokens(_ label: String, expiry: Date, accountID: String = "managed-id") -> CodexTokens {
        let payload = try! JSONSerialization.data(withJSONObject: ["account_id": accountID, "exp": Int(expiry.timeIntervalSince1970), "jti": label])
        let encoded = payload.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return CodexTokens(idToken: "fixture-id-\(label)", accessToken: "e30.\(encoded).sig", refreshToken: "fixture-refresh-\(label)", accountId: accountID)
    }
}
