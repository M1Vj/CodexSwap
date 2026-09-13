import Foundation
import XCTest
@testable import SwapKit

final class ManagedSourceReconciliationTests: XCTestCase {
    func testManagedSourceRotationAdoptsNewBundleAndPreservesControls() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("managed-source-rotation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let oldHome = root.appendingPathComponent("old-home", isDirectory: true)
        let newHome = root.appendingPathComponent("new-home", isDirectory: true)
        let accountID = "managed-account"
        let oldTokens = Self.tokens("old", expiry: Date().addingTimeInterval(60), accountID: accountID)
        let newTokens = Self.tokens("new", expiry: Date().addingTimeInterval(600), accountID: accountID)
        try CodexAuth.write(newTokens, to: newHome.appendingPathComponent("auth.json"))

        let telemetryID = UUID()
        let disabledUntil = Date().addingTimeInterval(3_600)
        let pausedAt = Date(timeIntervalSince1970: 1_000)
        let archivedAt = Date(timeIntervalSince1970: 2_000)
        let usage = [UsageWindow(label: "5h", usedPercent: 31, windowSeconds: 18_000, resetAt: disabledUntil)]
        let usageLimitSettings = AccountUsageLimitSettings(enabled: true, fiveHourPercent: 42, weeklyPercent: 73)
        let store = AccountStore(url: root.appendingPathComponent("accounts.json"))
        await store.upsert(Account(
            alias: "managed",
            email: "old@example.com",
            accountID: accountID,
            accessToken: oldTokens.accessToken,
            refreshToken: oldTokens.refreshToken,
            idToken: oldTokens.idToken,
            priority: 7,
            disabledUntil: ["quota": disabledUntil],
            needsLogin: true,
            lastUsedAt: Date(timeIntervalSince1970: 3_000),
            usage: usage,
            managedHomePath: oldHome.path,
            credentialSource: AccountCredentialSource(kind: .managedHome, path: oldHome.path),
            routingEnabled: false,
            archivedAt: archivedAt,
            routingPausedAt: pausedAt,
            telemetryID: telemetryID,
            usageLimitSettings: usageLimitSettings
        ))

        guard let incoming = AccountImporter.codexBarAccounts([
            CodexBarBridge.ManagedAccount(
                email: "new@example.com",
                accountID: accountID,
                managedHomePath: newHome.path
            )
        ]).first else {
            XCTFail("CodexBar managed source should import")
            return
        }
        let before = await store.account("managed")
        let merged = await store.reconcileManagedAccount(incoming)

        XCTAssertEqual(merged.alias, "managed")
        XCTAssertEqual(merged.accountID, accountID)
        XCTAssertEqual(merged.accessToken, newTokens.accessToken)
        XCTAssertEqual(merged.refreshToken, newTokens.refreshToken)
        XCTAssertEqual(merged.idToken, newTokens.idToken)
        XCTAssertEqual(merged.managedHomePath, newHome.path)
        XCTAssertEqual(merged.credentialSource, AccountCredentialSource(kind: .managedHome, path: newHome.path))
        XCTAssertTrue(merged.needsLogin)
        XCTAssertEqual(merged.priority, before?.priority)
        XCTAssertEqual(merged.disabledUntil, ["quota": disabledUntil])
        XCTAssertEqual(merged.lastUsedAt, Date(timeIntervalSince1970: 3_000))
        XCTAssertEqual(merged.usage, usage)
        XCTAssertFalse(merged.routingEnabled)
        XCTAssertEqual(merged.archivedAt, archivedAt)
        XCTAssertEqual(merged.routingPausedAt, pausedAt)
        XCTAssertEqual(merged.telemetryID, telemetryID)
        XCTAssertEqual(merged.usageLimitSettings, usageLimitSettings)
    }

    func testHydrationKeepsNeedsLoginForUnverifiedFutureManagedToken() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("managed-source-hydration-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let home = root.appendingPathComponent("managed-home", isDirectory: true)
        let authPath = home.appendingPathComponent("auth.json")
        let accountID = "managed-account"
        let storedTokens = Self.tokens("stored", expiry: Date().addingTimeInterval(60), accountID: accountID)
        let sourceTokens = Self.tokens("source", expiry: Date().addingTimeInterval(600), accountID: accountID)
        try CodexAuth.write(sourceTokens, to: authPath)
        let sourceBeforeHydration = try Data(contentsOf: authPath)

        let store = AccountStore(url: root.appendingPathComponent("accounts.json"))
        await store.upsert(Account(
            alias: "managed",
            accountID: accountID,
            accessToken: storedTokens.accessToken,
            refreshToken: storedTokens.refreshToken,
            idToken: storedTokens.idToken,
            needsLogin: true,
            managedHomePath: home.path
        ))

        guard let hydrated = await store.hydrateFromManagedHome("managed") else {
            XCTFail("Managed account should remain readable")
            return
        }
        XCTAssertEqual(hydrated.accessToken, sourceTokens.accessToken)
        XCTAssertEqual(hydrated.refreshToken, sourceTokens.refreshToken)
        XCTAssertTrue(hydrated.needsLogin)
        XCTAssertEqual(try Data(contentsOf: authPath), sourceBeforeHydration)
    }

    func testHydrationAdoptsChangedManagedBundleAtEqualExpiryAndPreservesControls() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("managed-source-equal-expiry-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let expiry = now.addingTimeInterval(3_600)
        let credentialOwner = "credential-owner"
        let storedTokens = Self.tokens("stored", expiry: expiry, accountID: credentialOwner)
        let sourceTokens = Self.tokens("source", expiry: expiry, accountID: credentialOwner)
        let home = root.appendingPathComponent("managed-home", isDirectory: true)
        let authPath = home.appendingPathComponent("auth.json")
        try CodexAuth.write(sourceTokens, to: authPath)
        let sourceBeforeHydration = try Data(contentsOf: authPath)

        let generation = UUID()
        let usage = [UsageWindow(label: "5h", usedPercent: 31, windowSeconds: 18_000, resetAt: expiry)]
        let disabledUntil = now.addingTimeInterval(1_800)
        let store = AccountStore(url: root.appendingPathComponent("accounts.json"), clock: { now })
        await store.upsert(Account(
            alias: "krisondaent",
            accountID: "selected-workspace",
            credentialAccountID: credentialOwner,
            accessToken: storedTokens.accessToken,
            refreshToken: storedTokens.refreshToken,
            idToken: storedTokens.idToken,
            priority: 7,
            disabledUntil: ["quota": disabledUntil],
            needsLogin: true,
            lastUsedAt: now.addingTimeInterval(-120),
            usage: usage,
            managedHomePath: home.path,
            credentialSource: AccountCredentialSource(kind: .managedHome, path: home.path),
            routingEnabled: false,
            archivedAt: now.addingTimeInterval(-300),
            routingPausedAt: now.addingTimeInterval(-60),
            telemetryID: UUID(),
            usageLimitSettings: AccountUsageLimitSettings(enabled: true, fiveHourPercent: 80, weeklyPercent: 90),
            authGeneration: generation
        ))

        let beforeValue = await store.account("krisondaent")
        let before = try XCTUnwrap(beforeValue)
        let hydratedValue = await store.hydrateFromManagedHome("krisondaent")
        let hydrated = try XCTUnwrap(hydratedValue)

        XCTAssertEqual(hydrated.accessToken, sourceTokens.accessToken)
        XCTAssertEqual(hydrated.refreshToken, sourceTokens.refreshToken)
        XCTAssertEqual(hydrated.idToken, sourceTokens.idToken)
        XCTAssertEqual(hydrated.accountID, "selected-workspace")
        XCTAssertEqual(hydrated.credentialAccountID, credentialOwner)
        XCTAssertEqual(hydrated.alias, before.alias)
        XCTAssertEqual(hydrated.priority, before.priority)
        XCTAssertEqual(hydrated.disabledUntil, before.disabledUntil)
        XCTAssertEqual(hydrated.needsLogin, true)
        XCTAssertEqual(hydrated.archivedAt, before.archivedAt)
        XCTAssertEqual(hydrated.usage, before.usage)
        XCTAssertEqual(hydrated.lastUsedAt, before.lastUsedAt)
        XCTAssertEqual(hydrated.routingEnabled, before.routingEnabled)
        XCTAssertEqual(hydrated.routingPausedAt, before.routingPausedAt)
        XCTAssertEqual(hydrated.usageLimitSettings, before.usageLimitSettings)
        XCTAssertEqual(hydrated.telemetryID, before.telemetryID)
        XCTAssertNotEqual(hydrated.authGeneration, before.authGeneration)
        XCTAssertEqual(try Data(contentsOf: authPath), sourceBeforeHydration)
    }

    func testHydrationLeavesIdenticalManagedBundleAndGenerationUnchanged() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("managed-source-identical-bundle-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let tokens = Self.tokens("identical", expiry: now.addingTimeInterval(3_600), accountID: "credential-owner")
        let home = root.appendingPathComponent("managed-home", isDirectory: true)
        let authPath = home.appendingPathComponent("auth.json")
        try CodexAuth.write(tokens, to: authPath)
        let sourceBeforeHydration = try Data(contentsOf: authPath)
        let generation = UUID()
        let storeURL = root.appendingPathComponent("accounts.json")
        let store = AccountStore(url: storeURL, clock: { now })
        await store.upsert(Account(
            alias: "krisondaent",
            accountID: "selected-workspace",
            credentialAccountID: "credential-owner",
            accessToken: tokens.accessToken,
            refreshToken: tokens.refreshToken,
            idToken: tokens.idToken,
            needsLogin: true,
            managedHomePath: home.path,
            authGeneration: generation
        ))
        let storeBeforeHydration = try Data(contentsOf: storeURL)
        let beforeValue = await store.account("krisondaent")
        let before = try XCTUnwrap(beforeValue)

        let hydratedValue = await store.hydrateFromManagedHome("krisondaent")
        let hydrated = try XCTUnwrap(hydratedValue)

        XCTAssertEqual(hydrated, before)
        XCTAssertEqual(hydrated.authGeneration, generation)
        XCTAssertEqual(try Data(contentsOf: storeURL), storeBeforeHydration)
        XCTAssertEqual(try Data(contentsOf: authPath), sourceBeforeHydration)
    }

    func testRejectedManagedTakeoverPreservesStandaloneWorkspaceAndOverlays() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("standalone-rejected-managed-takeover-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let credentialOwner = "credential-owner"
        let standaloneTokens = Self.tokens("standalone-owner", expiry: now.addingTimeInterval(3_600), accountID: credentialOwner)
        let standaloneHome = try Self.makeStandaloneHome(root: root, tokens: standaloneTokens)
        let managedHome = root.appendingPathComponent("managed-home", isDirectory: true)
        let managedTokens = Self.tokens("managed-incoming", expiry: now.addingTimeInterval(7_200), accountID: credentialOwner)
        try FileManager.default.createDirectory(at: managedHome, withIntermediateDirectories: true)
        try CodexAuth.write(managedTokens, to: managedHome.appendingPathComponent("auth.json"))

        let disabledUntil = now.addingTimeInterval(1_800)
        let archivedAt = now.addingTimeInterval(-600)
        let pausedAt = now.addingTimeInterval(-300)
        let lastUsedAt = now.addingTimeInterval(-120)
        let usage = [UsageWindow(label: "5h", usedPercent: 37, windowSeconds: 18_000, resetAt: disabledUntil)]
        let telemetryID = UUID()
        let usageLimits = AccountUsageLimitSettings(enabled: true, fiveHourPercent: 70, weeklyPercent: 85)
        var standalone = Account(
            alias: "standalone",
            email: "owner@example.com",
            accountID: "selected-workspace",
            credentialAccountID: credentialOwner,
            accessToken: standaloneTokens.accessToken,
            refreshToken: standaloneTokens.refreshToken,
            idToken: standaloneTokens.idToken,
            priority: 6,
            disabledUntil: ["quota": disabledUntil],
            needsLogin: true,
            lastUsedAt: lastUsedAt,
            usage: usage,
            credentialSource: AccountCredentialSource(
                kind: .standaloneHome,
                path: standaloneHome.appendingPathComponent("auth.json").path
            ),
            routingEnabled: false,
            archivedAt: archivedAt,
            routingPausedAt: pausedAt,
            telemetryID: telemetryID,
            usageLimitSettings: usageLimits
        )
        standalone.usageStats = UsageStats(totalRequests: 4, inputTokens: 120, outputTokens: 80)
        standalone.usageHistory = [WindowSample(capturedAt: lastUsedAt, label: "5h", usedPercent: 37)]
        standalone.lastServedByUs = lastUsedAt

        let store = AccountStore(url: root.appendingPathComponent("accounts.json"), clock: { now })
        await store.upsert(standalone)
        let beforeValue = await store.account("standalone")
        let before = try XCTUnwrap(beforeValue)
        let incoming = try XCTUnwrap(AccountImporter.codexBarAccounts([
            CodexBarBridge.ManagedAccount(
                email: "managed@example.com",
                accountID: "incoming-workspace",
                managedHomePath: managedHome.path
            )
        ]).first)

        let merged = await store.reconcileManagedAccount(
            incoming,
            presentAccountIDs: ["incoming-workspace"]
        )

        XCTAssertEqual(merged.accountID, "selected-workspace")
        XCTAssertEqual(merged.credentialAccountID, credentialOwner)
        XCTAssertEqual(merged.accessToken, standaloneTokens.accessToken)
        XCTAssertEqual(merged.refreshToken, standaloneTokens.refreshToken)
        XCTAssertEqual(merged.idToken, standaloneTokens.idToken)
        XCTAssertEqual(merged.credentialSource?.kind, .standaloneHome)
        XCTAssertEqual(merged.credentialSource?.path, standalone.credentialSource?.path)
        XCTAssertNil(merged.managedHomePath)
        XCTAssertEqual(merged.alias, standalone.alias)
        XCTAssertEqual(merged.priority, before.priority)
        XCTAssertEqual(merged.disabledUntil, standalone.disabledUntil)
        XCTAssertEqual(merged.needsLogin, standalone.needsLogin)
        XCTAssertEqual(merged.lastUsedAt, standalone.lastUsedAt)
        XCTAssertEqual(merged.usage, standalone.usage)
        XCTAssertEqual(merged.usageStats, standalone.usageStats)
        XCTAssertEqual(merged.usageHistory, standalone.usageHistory)
        XCTAssertEqual(merged.lastServedByUs, standalone.lastServedByUs)
        XCTAssertEqual(merged.archivedAt, standalone.archivedAt)
        XCTAssertEqual(merged.routingPausedAt, standalone.routingPausedAt)
        XCTAssertEqual(merged.routingEnabled, standalone.routingEnabled)
        XCTAssertEqual(merged.telemetryID, telemetryID)
        XCTAssertEqual(merged.usageLimitSettings, usageLimits)
    }

    func testInvalidStandaloneRowsDoNotDisplaceValidManagedOwner() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let cases: [(String, CodexTokens)] = [
            ("expired-row", Self.tokens("expired-row", expiry: now.addingTimeInterval(-60), accountID: "credential-owner")),
            ("mismatched-row", Self.tokens("mismatched-row", expiry: now.addingTimeInterval(3_600), accountID: "other-owner")),
        ]

        for (label, rowTokens) in cases {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("standalone-invalid-row-\(label)-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }

            let credentialOwner = "credential-owner"
            let sourceTokens = Self.tokens("fresh-home-\(label)", expiry: now.addingTimeInterval(3_600), accountID: credentialOwner)
            let standaloneHome = try Self.makeStandaloneHome(root: root, tokens: sourceTokens)
            let managedHome = root.appendingPathComponent("managed-home", isDirectory: true)
            let managedTokens = Self.tokens("managed-\(label)", expiry: now.addingTimeInterval(7_200), accountID: credentialOwner)
            try FileManager.default.createDirectory(at: managedHome, withIntermediateDirectories: true)
            try CodexAuth.write(managedTokens, to: managedHome.appendingPathComponent("auth.json"))

            let store = AccountStore(url: root.appendingPathComponent("accounts.json"), clock: { now })
            await store.upsert(Account(
                alias: "standalone",
                accountID: "selected-workspace",
                credentialAccountID: credentialOwner,
                accessToken: rowTokens.accessToken,
                refreshToken: rowTokens.refreshToken,
                idToken: rowTokens.idToken,
                credentialSource: AccountCredentialSource(
                    kind: .standaloneHome,
                    path: standaloneHome.appendingPathComponent("auth.json").path
                )
            ))
            let incoming = try XCTUnwrap(AccountImporter.codexBarAccounts([
                CodexBarBridge.ManagedAccount(
                    email: "managed@example.com",
                    accountID: "selected-workspace",
                    managedHomePath: managedHome.path
                )
            ]).first)

            let merged = await store.reconcileManagedAccount(
                incoming,
                presentAccountIDs: ["selected-workspace"]
            )

            XCTAssertEqual(merged.accessToken, managedTokens.accessToken, label)
            XCTAssertEqual(merged.refreshToken, managedTokens.refreshToken, label)
            XCTAssertEqual(merged.idToken, managedTokens.idToken, label)
            XCTAssertEqual(merged.credentialSource?.kind, .managedHome, label)
            XCTAssertEqual(merged.managedHomePath, managedHome.path, label)
        }
    }

    func testStalePersistenceKeepsValidStandaloneBundleAndSelectedWorkspace() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("standalone-stale-persistence-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let credentialOwner = "credential-owner"
        let sourceTokens = Self.tokens("valid-standalone", expiry: now.addingTimeInterval(3_600), accountID: credentialOwner)
        let home = try Self.makeStandaloneHome(root: root, tokens: sourceTokens)
        let source = AccountCredentialSource(
            kind: .standaloneHome,
            path: home.appendingPathComponent("auth.json").path
        )
        let seed = AccountStore(url: root.appendingPathComponent("accounts.json"), clock: { now })
        await seed.upsert(Account(
            alias: "standalone",
            accountID: "selected-workspace",
            credentialAccountID: credentialOwner,
            accessToken: sourceTokens.accessToken,
            refreshToken: sourceTokens.refreshToken,
            idToken: sourceTokens.idToken,
            usage: [UsageWindow(label: "5h", usedPercent: 10, windowSeconds: 18_000, resetAt: nil)],
            credentialSource: source
        ))

        let latest = AccountStore(url: root.appendingPathComponent("accounts.json"), clock: { now })
        let stale = AccountStore(url: root.appendingPathComponent("accounts.json"), clock: { now })
        let freshUsage = [UsageWindow(label: "5h", usedPercent: 61, windowSeconds: 18_000, resetAt: now.addingTimeInterval(1_800))]
        await latest.updateUsage("standalone", windows: freshUsage)
        let invalidTokens = Self.tokens("stale-invalid", expiry: now.addingTimeInterval(-60), accountID: credentialOwner)
        await stale.updateTokens("standalone", tokens: invalidTokens, clearNeedsLogin: false)

        let reloaded = AccountStore(url: root.appendingPathComponent("accounts.json"), clock: { now })
        let retainedValue = await reloaded.account("standalone")
        let retained = try XCTUnwrap(retainedValue)

        XCTAssertEqual(retained.accountID, "selected-workspace")
        XCTAssertEqual(retained.credentialAccountID, credentialOwner)
        XCTAssertEqual(retained.accessToken, sourceTokens.accessToken)
        XCTAssertEqual(retained.refreshToken, sourceTokens.refreshToken)
        XCTAssertEqual(retained.idToken, sourceTokens.idToken)
        XCTAssertEqual(retained.credentialSource, source)
        XCTAssertEqual(retained.usage, freshUsage)
    }

    func testLegacyNativeAuthMigrationRejectsMismatchedCandidateBundle() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("legacy-native-mismatch-migration-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let credentialOwner = "credential-owner"
        let sourceTokens = Self.tokens("verified-home", expiry: now.addingTimeInterval(3_600), accountID: credentialOwner)
        let home = try Self.makeStandaloneHome(root: root, tokens: sourceTokens)
        let rowTokens = Self.tokens("row-other-owner", expiry: now.addingTimeInterval(3_600), accountID: "other-owner")
        let authPath = home.appendingPathComponent("auth.json").path
        let legacy = Account(
            alias: "legacy",
            accountID: "selected-workspace",
            credentialAccountID: credentialOwner,
            accessToken: rowTokens.accessToken,
            refreshToken: rowTokens.refreshToken,
            idToken: rowTokens.idToken,
            credentialSource: AccountCredentialSource(kind: .nativeAuth, path: authPath)
        )
        let storeURL = root.appendingPathComponent("accounts.json")
        try JSONEncoder.codex.encode(StoreData(accounts: [legacy])).write(to: storeURL)

        let store = AccountStore(url: storeURL, clock: { now })
        let retainedValue = await store.account("legacy")
        let retained = try XCTUnwrap(retainedValue)

        XCTAssertEqual(retained.credentialSource?.kind, .nativeAuth)
        XCTAssertEqual(retained.credentialSource?.path, authPath)
    }

    func testLegacyNativeAuthMigrationRejectsArbitraryPlausiblePath() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("legacy-native-arbitrary-migration-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let accountID = "arbitrary-account"
        let tokens = Self.tokens("arbitrary-path", expiry: now.addingTimeInterval(3_600), accountID: accountID)
        let arbitraryHome = root.appendingPathComponent("plausible-home-\(UUID().uuidString)", isDirectory: true)
        let authPath = arbitraryHome.appendingPathComponent("auth.json")
        try FileManager.default.createDirectory(at: arbitraryHome, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try CodexAuth.write(tokens, to: authPath)
        try Data("completed\n".utf8).write(to: arbitraryHome.appendingPathComponent(CodexLoginLauncher.successMarkerName))

        let legacy = Account(
            alias: "legacy-arbitrary",
            accountID: accountID,
            accessToken: tokens.accessToken,
            refreshToken: tokens.refreshToken,
            idToken: tokens.idToken,
            credentialSource: AccountCredentialSource(kind: .nativeAuth, path: authPath.path)
        )
        let storeURL = root.appendingPathComponent("accounts.json")
        try JSONEncoder.codex.encode(StoreData(accounts: [legacy])).write(to: storeURL)

        let store = AccountStore(url: storeURL, clock: { now })
        let retainedValue = await store.account("legacy-arbitrary")
        let retained = try XCTUnwrap(retainedValue)

        XCTAssertEqual(retained.credentialSource?.kind, .nativeAuth)
        XCTAssertEqual(retained.credentialSource?.path, authPath.path)
    }

    func testStandaloneCredentialSourceEncodingUsesLegacyKindAndDiscriminator() throws {
        let source = AccountCredentialSource(
            kind: .standaloneHome,
            path: "/tmp/codexswap-standalone/auth.json"
        )
        let encoded = try JSONEncoder.codex.encode(source)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])

        XCTAssertEqual(object["kind"] as? String, "nativeAuth")
        XCTAssertEqual(object["owner"] as? String, "codexswapStandalone")
        let legacyDecoded = try JSONDecoder.codex.decode(LegacyCredentialSourceFixture.self, from: encoded)
        XCTAssertEqual(legacyDecoded.kind, .nativeAuth)
        let decoded = try JSONDecoder.codex.decode(AccountCredentialSource.self, from: encoded)
        XCTAssertEqual(decoded, source)
    }

    func testLegacyNativeAuthCredentialSourceWithoutDiscriminatorRemainsNativeAuth() throws {
        let data = Data(#"{"kind":"nativeAuth","path":"/tmp/codexswap-native/auth.json"}"#.utf8)
        let decoded = try JSONDecoder.codex.decode(AccountCredentialSource.self, from: data)

        XCTAssertEqual(decoded.kind, .nativeAuth)
        XCTAssertEqual(decoded.path, "/tmp/codexswap-native/auth.json")
    }

    func testHydrationRejectsChangedEqualExpiryNativeAndLegacyBundles() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let expiry = now.addingTimeInterval(3_600)
        let sourceKinds: [(String, AccountCredentialSource.Kind)] = [
            ("native-auth", .nativeAuth),
            ("legacy-snapshot", .legacySnapshot),
        ]

        for (label, sourceKind) in sourceKinds {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("equal-expiry-\(label)-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }

            let accountID = "\(label)-account"
            let storedTokens = Self.tokens("stored-\(label)", expiry: expiry, accountID: accountID)
            let sourceTokens = Self.tokens("source-\(label)", expiry: expiry, accountID: accountID)
            let sourcePath = root.appendingPathComponent("auth.json")
            try CodexAuth.write(sourceTokens, to: sourcePath)
            let sourceBeforeHydration = try Data(contentsOf: sourcePath)
            let generation = UUID()
            let storeURL = root.appendingPathComponent("accounts.json")
            let store = AccountStore(url: storeURL, clock: { now })
            await store.upsert(Account(
                alias: label,
                accountID: accountID,
                accessToken: storedTokens.accessToken,
                refreshToken: storedTokens.refreshToken,
                idToken: storedTokens.idToken,
                credentialSource: AccountCredentialSource(kind: sourceKind, path: sourcePath.path),
                authGeneration: generation
            ))
            let storeBeforeHydration = try Data(contentsOf: storeURL)

            let hydratedValue = await store.hydrateFromManagedHome(label)
            let hydrated = try XCTUnwrap(hydratedValue)

            XCTAssertEqual(hydrated.accessToken, storedTokens.accessToken, label)
            XCTAssertEqual(hydrated.refreshToken, storedTokens.refreshToken, label)
            XCTAssertEqual(hydrated.idToken, storedTokens.idToken, label)
            XCTAssertEqual(hydrated.authGeneration, generation, label)
            XCTAssertEqual(try Data(contentsOf: storeURL), storeBeforeHydration, label)
            XCTAssertEqual(try Data(contentsOf: sourcePath), sourceBeforeHydration, label)
        }
    }

    func testVerifiedStandaloneHomeWinsManagedDuplicateAndRemainsOwner() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("standalone-precedence-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let accountID = "selected-workspace"
        let credentialOwner = "credential-owner"
        let standaloneTokens = Self.tokens("standalone", expiry: now.addingTimeInterval(1_800), accountID: credentialOwner)
        let managedTokens = Self.tokens("managed", expiry: now.addingTimeInterval(3_600), accountID: credentialOwner)
        _ = try Self.makeStandaloneHome(root: root, tokens: standaloneTokens)
        let managedHome = root.appendingPathComponent("managed-home", isDirectory: true)
        try FileManager.default.createDirectory(at: managedHome, withIntermediateDirectories: true)
        try CodexAuth.write(managedTokens, to: managedHome.appendingPathComponent("auth.json"))

        let store = AccountStore(url: root.appendingPathComponent("accounts.json"), clock: { now })
        let managed = Account(
            alias: "managed",
            accountID: accountID,
            credentialAccountID: credentialOwner,
            accessToken: managedTokens.accessToken,
            refreshToken: managedTokens.refreshToken,
            idToken: managedTokens.idToken,
            usage: [UsageWindow(label: "5h", usedPercent: 44, windowSeconds: 18_000, resetAt: nil)],
            managedHomePath: managedHome.path
        )
        await store.upsert(managed)
        let storedManagedValue = await store.account("managed")
        let storedManaged = try XCTUnwrap(storedManagedValue)
        XCTAssertEqual(storedManaged.accountID, accountID)
        XCTAssertEqual(storedManaged.credentialAccountID, credentialOwner)

        let standalone = try XCTUnwrap(
            AccountImporter.standaloneCodexAuthAccounts(supportDirectory: root, now: now).first
        )
        XCTAssertEqual(standalone.accountID, credentialOwner)
        XCTAssertEqual(standalone.credentialAccountID, credentialOwner)
        XCTAssertEqual(standalone.credentialSource?.kind, .standaloneHome)
        XCTAssertNotNil(StandaloneAccountRemoval.verifiedAuthURL(standalone, supportDirectory: root))

        let adopted = await store.upsert(standalone)
        XCTAssertEqual(adopted.accountID, accountID)
        XCTAssertEqual(adopted.credentialAccountID, credentialOwner)
        XCTAssertEqual(adopted.accessToken, standaloneTokens.accessToken)
        XCTAssertEqual(adopted.credentialSource?.kind, .standaloneHome)
        XCTAssertNil(adopted.managedHomePath)
        XCTAssertEqual(adopted.usage, managed.usage)

        let nativeTokens = Self.tokens("native", expiry: now.addingTimeInterval(7_200), accountID: credentialOwner)
        let nativeAuth = root.appendingPathComponent("native-auth.json")
        try CodexAuth.write(nativeTokens, to: nativeAuth)
        let native = Account(
            alias: "ambient",
            accountID: accountID,
            accessToken: nativeTokens.accessToken,
            refreshToken: nativeTokens.refreshToken,
            idToken: nativeTokens.idToken,
            credentialSource: AccountCredentialSource(kind: .nativeAuth, path: nativeAuth.path)
        )
        let afterNative = await store.upsert(native)
        XCTAssertEqual(afterNative.accessToken, standaloneTokens.accessToken)
        XCTAssertEqual(afterNative.credentialSource?.kind, .standaloneHome)
        XCTAssertNil(afterNative.managedHomePath)

        let managedAgain = try XCTUnwrap(AccountImporter.codexBarAccounts([
            CodexBarBridge.ManagedAccount(email: "managed@example.com", accountID: accountID, managedHomePath: managedHome.path)
        ]).first)
        let afterReconcile = await store.reconcileManagedAccount(
            managedAgain,
            presentAccountIDs: [accountID]
        )
        XCTAssertEqual(afterReconcile.accessToken, standaloneTokens.accessToken)
        XCTAssertEqual(afterReconcile.credentialSource?.kind, .standaloneHome)
        XCTAssertNil(afterReconcile.managedHomePath)
    }

    func testStandaloneHydrationAdoptsVerifiedBundleAndPreservesSelectedWorkspace() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("standalone-source-hydration-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let credentialOwner = "credential-owner"
        let storedTokens = Self.tokens("stored", expiry: now.addingTimeInterval(60), accountID: credentialOwner)
        let sourceTokens = Self.tokens("source", expiry: now.addingTimeInterval(1_800), accountID: credentialOwner)
        let home = try Self.makeStandaloneHome(root: root, tokens: sourceTokens)
        let authPath = home.appendingPathComponent("auth.json")
        let sourceBeforeHydration = try Data(contentsOf: authPath)
        let usage = [UsageWindow(label: "5h", usedPercent: 27, windowSeconds: 18_000, resetAt: nil)]
        let store = AccountStore(url: root.appendingPathComponent("accounts.json"), clock: { now })
        await store.upsert(Account(
            alias: "standalone",
            accountID: "selected-workspace",
            credentialAccountID: credentialOwner,
            accessToken: storedTokens.accessToken,
            refreshToken: storedTokens.refreshToken,
            idToken: storedTokens.idToken,
            needsLogin: true,
            usage: usage,
            credentialSource: AccountCredentialSource(kind: .standaloneHome, path: authPath.path)
        ))

        let hydratedValue = await store.hydrateFromManagedHome("standalone")
        let hydrated = try XCTUnwrap(hydratedValue)

        XCTAssertEqual(hydrated.accountID, "selected-workspace")
        XCTAssertEqual(hydrated.credentialAccountID, credentialOwner)
        XCTAssertEqual(hydrated.accessToken, sourceTokens.accessToken)
        XCTAssertEqual(hydrated.refreshToken, sourceTokens.refreshToken)
        XCTAssertEqual(hydrated.idToken, sourceTokens.idToken)
        XCTAssertEqual(hydrated.usage, usage)
        XCTAssertTrue(hydrated.needsLogin)
        XCTAssertEqual(hydrated.credentialSource?.kind, .standaloneHome)
        XCTAssertEqual(try Data(contentsOf: authPath), sourceBeforeHydration)
    }

    func testUpdateTokensPreservesStandaloneSelectedWorkspaceAndOverlays() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("standalone-update-tokens-workspace-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let credentialOwner = "credential-owner"
        let selectedWorkspace = "selected-workspace"
        let currentTokens = Self.tokens("standalone-current", expiry: now.addingTimeInterval(3_600), accountID: credentialOwner)
        let refreshedTokens = Self.tokens("standalone-refreshed", expiry: now.addingTimeInterval(7_200), accountID: credentialOwner)
        let home = try Self.makeStandaloneHome(root: root, tokens: currentTokens)
        let source = AccountCredentialSource(
            kind: .standaloneHome,
            path: home.appendingPathComponent("auth.json").path
        )
        let disabledUntil = now.addingTimeInterval(1_800)
        let lastUsedAt = now.addingTimeInterval(-120)
        let usage = [UsageWindow(label: "5h", usedPercent: 41, windowSeconds: 18_000, resetAt: disabledUntil)]
        let usageStats = UsageStats(totalRequests: 3, inputTokens: 80, outputTokens: 55)
        let usageHistory = [WindowSample(capturedAt: lastUsedAt, label: "5h", usedPercent: 41)]
        let telemetryID = UUID()
        let generation = UUID()
        var account = Account(
            alias: "standalone",
            email: "owner@example.com",
            accountID: selectedWorkspace,
            credentialAccountID: credentialOwner,
            accessToken: currentTokens.accessToken,
            refreshToken: currentTokens.refreshToken,
            idToken: currentTokens.idToken,
            priority: 5,
            disabledUntil: ["quota": disabledUntil],
            needsLogin: true,
            lastUsedAt: lastUsedAt,
            usage: usage,
            credentialSource: source,
            routingEnabled: false,
            telemetryID: telemetryID,
            authGeneration: generation
        )
        account.usageStats = usageStats
        account.usageHistory = usageHistory
        account.lastServedByUs = lastUsedAt

        let storeURL = root.appendingPathComponent("accounts.json")
        let store = AccountStore(url: storeURL, clock: { now })
        await store.upsert(account)
        let beforeValue = await store.account("standalone")
        let before = try XCTUnwrap(beforeValue)

        await store.updateTokens(
            "standalone",
            tokens: refreshedTokens,
            clearNeedsLogin: false
        )

        let updatedValue = await store.account("standalone")
        let updated = try XCTUnwrap(updatedValue)
        XCTAssertEqual(updated.accountID, selectedWorkspace)
        XCTAssertEqual(updated.credentialAccountID, credentialOwner)
        XCTAssertEqual(updated.accessToken, refreshedTokens.accessToken)
        XCTAssertEqual(updated.refreshToken, refreshedTokens.refreshToken)
        XCTAssertEqual(updated.idToken, refreshedTokens.idToken)
        XCTAssertEqual(updated.credentialSource, source)
        XCTAssertEqual(updated.priority, before.priority)
        XCTAssertEqual(updated.disabledUntil, before.disabledUntil)
        XCTAssertEqual(updated.needsLogin, before.needsLogin)
        XCTAssertEqual(updated.lastUsedAt, before.lastUsedAt)
        XCTAssertEqual(updated.usage, before.usage)
        XCTAssertEqual(updated.usageStats, before.usageStats)
        XCTAssertEqual(updated.usageHistory, before.usageHistory)
        XCTAssertEqual(updated.lastServedByUs, before.lastServedByUs)
        XCTAssertEqual(updated.telemetryID, telemetryID)
        XCTAssertNotEqual(updated.authGeneration, before.authGeneration)

        let reloaded = AccountStore(url: storeURL, clock: { now })
        let reloadedValue = await reloaded.account("standalone")
        let reloadedAccount = try XCTUnwrap(reloadedValue)
        XCTAssertEqual(reloadedAccount.accountID, selectedWorkspace)
        XCTAssertEqual(reloadedAccount.credentialAccountID, credentialOwner)
        XCTAssertEqual(reloadedAccount.accessToken, refreshedTokens.accessToken)
        XCTAssertEqual(reloadedAccount.refreshToken, refreshedTokens.refreshToken)
        XCTAssertEqual(reloadedAccount.idToken, refreshedTokens.idToken)
        XCTAssertEqual(reloadedAccount.credentialSource, source)
        XCTAssertEqual(reloadedAccount.usage, usage)
        XCTAssertEqual(reloadedAccount.disabledUntil, ["quota": disabledUntil])
        XCTAssertEqual(reloadedAccount.telemetryID, telemetryID)
    }

    func testLegacyNativeStandaloneSourceMigratesOnlyFromVerifiedHome() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("standalone-source-migration-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let tokens = Self.tokens("legacy", expiry: now.addingTimeInterval(1_800), accountID: "legacy-account")
        let home = try Self.makeStandaloneHome(root: root, tokens: tokens)
        let legacy = Account(
            alias: "legacy",
            accountID: tokens.accountId,
            accessToken: tokens.accessToken,
            refreshToken: tokens.refreshToken,
            idToken: tokens.idToken,
            credentialSource: AccountCredentialSource(
                kind: .nativeAuth,
                path: home.appendingPathComponent("auth.json").path
            )
        )
        let storeURL = root.appendingPathComponent("accounts.json")
        try JSONEncoder.codex.encode(StoreData(accounts: [legacy])).write(to: storeURL)

        let store = AccountStore(url: storeURL, clock: { now })
        let migratedValue = await store.account("legacy")
        let migrated = try XCTUnwrap(migratedValue)

        XCTAssertEqual(migrated.credentialSource?.kind, .standaloneHome)
        XCTAssertEqual(migrated.credentialSource?.path, home.appendingPathComponent("auth.json").path)
    }

    func testExpiredStandaloneHomeDoesNotDisplaceValidManagedOwner() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("standalone-invalid-precedence-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let accountID = "same-account"
        let expiredTokens = Self.tokens("expired", expiry: now.addingTimeInterval(-60), accountID: accountID)
        let managedTokens = Self.tokens("managed", expiry: now.addingTimeInterval(3_600), accountID: accountID)
        let standaloneHome = try Self.makeStandaloneHome(root: root, tokens: expiredTokens)
        let managedHome = root.appendingPathComponent("managed-home", isDirectory: true)
        try FileManager.default.createDirectory(at: managedHome, withIntermediateDirectories: true)
        try CodexAuth.write(managedTokens, to: managedHome.appendingPathComponent("auth.json"))

        let store = AccountStore(url: root.appendingPathComponent("accounts.json"), clock: { now })
        await store.upsert(Account(
            alias: "standalone",
            accountID: accountID,
            accessToken: expiredTokens.accessToken,
            refreshToken: expiredTokens.refreshToken,
            idToken: expiredTokens.idToken,
            credentialSource: AccountCredentialSource(
                kind: .standaloneHome,
                path: standaloneHome.appendingPathComponent("auth.json").path
            )
        ))

        let managed = try XCTUnwrap(AccountImporter.codexBarAccounts([
            CodexBarBridge.ManagedAccount(email: "managed@example.com", accountID: accountID, managedHomePath: managedHome.path)
        ]).first)
        let merged = await store.reconcileManagedAccount(managed, presentAccountIDs: [accountID])

        XCTAssertEqual(merged.accessToken, managedTokens.accessToken)
        XCTAssertEqual(merged.credentialSource?.kind, .managedHome)
        XCTAssertEqual(merged.managedHomePath, managedHome.path)
    }

    func testStandaloneRecoveryPreservesSelectedWorkspaceIdentity() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("standalone-recovery-workspace-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let credentialOwner = "credential-owner"
        let tokens = Self.tokens("standalone", expiry: now.addingTimeInterval(1_800), accountID: credentialOwner)
        let home = try Self.makeStandaloneHome(root: root, tokens: tokens)
        let account = Account(
            alias: "standalone",
            accountID: "selected-workspace",
            credentialAccountID: credentialOwner,
            accessToken: tokens.accessToken,
            refreshToken: tokens.refreshToken,
            idToken: tokens.idToken,
            needsLogin: true,
            credentialSource: AccountCredentialSource(
                kind: .standaloneHome,
                path: home.appendingPathComponent("auth.json").path
            )
        )

        let candidate = try XCTUnwrap(AuthenticationRecovery.candidate(for: account))

        XCTAssertEqual(candidate.accountID, account.accountID)
        XCTAssertEqual(candidate.credentialAccountID, credentialOwner)
        XCTAssertTrue(AuthenticationRecovery.accepts(candidate, for: account, now: now))
    }

    func testAmbientNativeDuplicateCannotDisplaceManagedOwner() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ambient-precedence-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let accountID = "same-account"
        let managedTokens = Self.tokens("managed", expiry: Date().addingTimeInterval(60), accountID: accountID)
        let ambientTokens = Self.tokens("ambient", expiry: Date().addingTimeInterval(3_600), accountID: accountID)
        let managedHome = root.appendingPathComponent("managed-home", isDirectory: true)
        try FileManager.default.createDirectory(at: managedHome, withIntermediateDirectories: true)
        try CodexAuth.write(managedTokens, to: managedHome.appendingPathComponent("auth.json"))

        let store = AccountStore(url: root.appendingPathComponent("accounts.json"))
        let managed = try XCTUnwrap(AccountImporter.codexBarAccounts([
            CodexBarBridge.ManagedAccount(email: "managed@example.com", accountID: accountID, managedHomePath: managedHome.path)
        ]).first)
        await store.reconcileManagedAccount(managed, presentAccountIDs: [accountID])
        let ambientAuth = root.appendingPathComponent("ambient-auth.json")
        try CodexAuth.write(ambientTokens, to: ambientAuth)
        let ambient = Account(
            alias: "ambient",
            accountID: accountID,
            accessToken: ambientTokens.accessToken,
            refreshToken: ambientTokens.refreshToken,
            idToken: ambientTokens.idToken,
            credentialSource: AccountCredentialSource(
                kind: .nativeAuth,
                path: ambientAuth.path
            )
        )

        let merged = await store.upsert(ambient)

        XCTAssertEqual(merged.accessToken, managedTokens.accessToken)
        XCTAssertEqual(merged.credentialSource?.kind, .managedHome)
        XCTAssertEqual(merged.managedHomePath, managedHome.path)
    }

    func testExpiredManagedOwnerCannotBePersistentlyDisplacedByNativeImport() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("expired-managed-persistent-owner-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let accountID = "same-account"
        let managedTokens = Self.tokens("expired-managed", expiry: now.addingTimeInterval(-60), accountID: accountID)
        let nativeTokens = Self.tokens("valid-native", expiry: now.addingTimeInterval(3_600), accountID: accountID)
        let managedHome = root.appendingPathComponent("managed-home", isDirectory: true)
        let nativeAuth = root.appendingPathComponent("native-auth.json")
        try FileManager.default.createDirectory(at: managedHome, withIntermediateDirectories: true)
        try CodexAuth.write(managedTokens, to: managedHome.appendingPathComponent("auth.json"))
        try CodexAuth.write(nativeTokens, to: nativeAuth)
        let store = AccountStore(url: root.appendingPathComponent("accounts.json"), clock: { now })
        await store.upsert(Account(
            alias: "krisondaent",
            accountID: accountID,
            accessToken: managedTokens.accessToken,
            refreshToken: managedTokens.refreshToken,
            idToken: managedTokens.idToken,
            managedHomePath: managedHome.path,
            credentialSource: AccountCredentialSource(kind: .managedHome, path: managedHome.path)
        ))

        let merged = await store.upsert(Account(
            alias: "ambient",
            accountID: accountID,
            accessToken: nativeTokens.accessToken,
            refreshToken: nativeTokens.refreshToken,
            idToken: nativeTokens.idToken,
            credentialSource: AccountCredentialSource(kind: .nativeAuth, path: nativeAuth.path)
        ))

        XCTAssertEqual(merged.alias, "krisondaent")
        XCTAssertEqual(merged.accessToken, managedTokens.accessToken)
        XCTAssertEqual(merged.credentialSource?.kind, .managedHome)
        XCTAssertEqual(merged.managedHomePath, managedHome.path)
    }

    func testValidManagedHydrationDoesNotUseAmbientNativeCredential() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("valid-managed-no-native-fallback-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let accountID = "same-account"
        let managedTokens = Self.tokens("valid-managed", expiry: now.addingTimeInterval(1_800), accountID: accountID)
        let nativeTokens = Self.tokens("valid-native", expiry: now.addingTimeInterval(3_600), accountID: accountID)
        let managedHome = root.appendingPathComponent("managed-home", isDirectory: true)
        let nativeAuth = root.appendingPathComponent("native-auth.json")
        try FileManager.default.createDirectory(at: managedHome, withIntermediateDirectories: true)
        try CodexAuth.write(managedTokens, to: managedHome.appendingPathComponent("auth.json"))
        try CodexAuth.write(nativeTokens, to: nativeAuth)
        let native = Account(
            alias: "ambient",
            accountID: accountID,
            accessToken: nativeTokens.accessToken,
            refreshToken: nativeTokens.refreshToken,
            idToken: nativeTokens.idToken,
            credentialSource: AccountCredentialSource(kind: .nativeAuth, path: nativeAuth.path)
        )
        let store = AccountStore(
            url: root.appendingPathComponent("accounts.json"),
            clock: { now },
            ambientNativeAccountProvider: { native }
        )
        await store.upsert(Account(
            alias: "krisondaent",
            accountID: accountID,
            accessToken: managedTokens.accessToken,
            refreshToken: managedTokens.refreshToken,
            idToken: managedTokens.idToken,
            managedHomePath: managedHome.path,
            credentialSource: AccountCredentialSource(kind: .managedHome, path: managedHome.path)
        ))

        let hydratedValue = await store.hydrateFromManagedHome("krisondaent")
        let hydrated = try XCTUnwrap(hydratedValue)

        XCTAssertEqual(hydrated.accessToken, managedTokens.accessToken)
        XCTAssertEqual(hydrated.credentialSource?.kind, .managedHome)
        XCTAssertEqual(hydrated.managedHomePath, managedHome.path)
    }

    func testUnreadableManagedHydrationUsesMatchingNativeRuntimeOverlay() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("unreadable-managed-native-fallback-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let accountID = "same-account"
        let managedTokens = Self.tokens("missing-managed", expiry: now.addingTimeInterval(-60), accountID: accountID)
        let nativeTokens = Self.tokens("valid-native", expiry: now.addingTimeInterval(3_600), accountID: accountID)
        let managedHome = root.appendingPathComponent("managed-home", isDirectory: true)
        let nativeAuth = root.appendingPathComponent("native-auth.json")
        try FileManager.default.createDirectory(at: managedHome, withIntermediateDirectories: true)
        try CodexAuth.write(nativeTokens, to: nativeAuth)
        let native = Account(
            alias: "ambient",
            accountID: accountID,
            accessToken: nativeTokens.accessToken,
            refreshToken: nativeTokens.refreshToken,
            idToken: nativeTokens.idToken,
            credentialSource: AccountCredentialSource(kind: .nativeAuth, path: nativeAuth.path)
        )
        let storeURL = root.appendingPathComponent("accounts.json")
        let store = AccountStore(
            url: storeURL,
            clock: { now },
            ambientNativeAccountProvider: { native }
        )
        await store.upsert(Account(
            alias: "krisondaent",
            accountID: accountID,
            accessToken: managedTokens.accessToken,
            refreshToken: managedTokens.refreshToken,
            idToken: managedTokens.idToken,
            managedHomePath: managedHome.path,
            credentialSource: AccountCredentialSource(kind: .managedHome, path: managedHome.path)
        ))
        let storeBefore = try Data(contentsOf: storeURL)

        let hydratedValue = await store.hydrateFromManagedHome("krisondaent")
        let hydrated = try XCTUnwrap(hydratedValue)

        XCTAssertEqual(hydrated.accessToken, nativeTokens.accessToken)
        XCTAssertEqual(hydrated.credentialSource?.kind, .managedHome)
        XCTAssertEqual(try Data(contentsOf: storeURL), storeBefore)
    }

    func testExpiredManagedHydrationUsesMatchingNativeRuntimeOverlayWithoutMutation() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("managed-native-runtime-fallback-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let accountID = "same-account"
        let managedTokens = Self.tokens("expired-managed", expiry: now.addingTimeInterval(-60), accountID: accountID)
        let nativeTokens = Self.tokens("valid-native", expiry: now.addingTimeInterval(3_600), accountID: accountID)
        let managedHome = root.appendingPathComponent("managed-home", isDirectory: true)
        let managedAuth = managedHome.appendingPathComponent("auth.json")
        let nativeAuth = root.appendingPathComponent("native-auth.json")
        try FileManager.default.createDirectory(at: managedHome, withIntermediateDirectories: true)
        try CodexAuth.write(managedTokens, to: managedAuth)
        try CodexAuth.write(nativeTokens, to: nativeAuth)

        let native = Account(
            alias: "ambient",
            accountID: accountID,
            accessToken: nativeTokens.accessToken,
            refreshToken: nativeTokens.refreshToken,
            idToken: nativeTokens.idToken,
            credentialSource: AccountCredentialSource(kind: .nativeAuth, path: nativeAuth.path)
        )
        let usage = [UsageWindow(label: "5h", usedPercent: 100, windowSeconds: 18_000, resetAt: now)]
        let storeURL = root.appendingPathComponent("accounts.json")
        let store = AccountStore(
            url: storeURL,
            clock: { now },
            ambientNativeAccountProvider: { native }
        )
        await store.upsert(Account(
            alias: "krisondaent",
            accountID: accountID,
            accessToken: managedTokens.accessToken,
            refreshToken: managedTokens.refreshToken,
            idToken: managedTokens.idToken,
            usage: usage,
            managedHomePath: managedHome.path,
            credentialSource: AccountCredentialSource(kind: .managedHome, path: managedHome.path)
        ))

        let storeBefore = try Data(contentsOf: storeURL)
        let managedBefore = try Data(contentsOf: managedAuth)
        let nativeBefore = try Data(contentsOf: nativeAuth)
        let hydratedValue = await store.hydrateFromManagedHome("krisondaent")
        let hydrated = try XCTUnwrap(hydratedValue)

        XCTAssertEqual(hydrated.accessToken, nativeTokens.accessToken)
        XCTAssertEqual(hydrated.refreshToken, nativeTokens.refreshToken)
        XCTAssertEqual(hydrated.idToken, nativeTokens.idToken)
        XCTAssertEqual(hydrated.accountID, accountID)
        XCTAssertEqual(hydrated.credentialSource?.kind, .managedHome)
        XCTAssertEqual(hydrated.managedHomePath, managedHome.path)
        XCTAssertEqual(hydrated.usage, usage)

        let storedValue = await store.account("krisondaent")
        let stored = try XCTUnwrap(storedValue)
        XCTAssertEqual(stored.accessToken, managedTokens.accessToken)
        XCTAssertEqual(stored.credentialSource?.kind, .managedHome)
        XCTAssertEqual(try Data(contentsOf: storeURL), storeBefore)
        XCTAssertEqual(try Data(contentsOf: managedAuth), managedBefore)
        XCTAssertEqual(try Data(contentsOf: nativeAuth), nativeBefore)
    }

    func testExpiredManagedHydrationRejectsMismatchedNativeRuntimeOverlay() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("managed-native-runtime-mismatch-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let managedID = "managed-account"
        let nativeID = "other-account"
        let managedTokens = Self.tokens("expired-managed", expiry: now.addingTimeInterval(-60), accountID: managedID)
        let nativeTokens = Self.tokens("mismatched-native", expiry: now.addingTimeInterval(3_600), accountID: nativeID)
        let managedHome = root.appendingPathComponent("managed-home", isDirectory: true)
        let managedAuth = managedHome.appendingPathComponent("auth.json")
        let nativeAuth = root.appendingPathComponent("native-auth.json")
        try FileManager.default.createDirectory(at: managedHome, withIntermediateDirectories: true)
        try CodexAuth.write(managedTokens, to: managedAuth)
        try CodexAuth.write(nativeTokens, to: nativeAuth)

        let native = Account(
            alias: "ambient",
            accountID: nativeID,
            accessToken: nativeTokens.accessToken,
            refreshToken: nativeTokens.refreshToken,
            idToken: nativeTokens.idToken,
            credentialSource: AccountCredentialSource(kind: .nativeAuth, path: nativeAuth.path)
        )
        let storeURL = root.appendingPathComponent("accounts.json")
        let store = AccountStore(
            url: storeURL,
            clock: { now },
            ambientNativeAccountProvider: { native }
        )
        await store.upsert(Account(
            alias: "krisondaent",
            accountID: managedID,
            accessToken: managedTokens.accessToken,
            refreshToken: managedTokens.refreshToken,
            idToken: managedTokens.idToken,
            managedHomePath: managedHome.path,
            credentialSource: AccountCredentialSource(kind: .managedHome, path: managedHome.path)
        ))

        let storeBefore = try Data(contentsOf: storeURL)
        let hydratedValue = await store.hydrateFromManagedHome("krisondaent")
        let hydrated = try XCTUnwrap(hydratedValue)

        XCTAssertEqual(hydrated.accessToken, managedTokens.accessToken)
        XCTAssertEqual(hydrated.credentialSource?.kind, .managedHome)
        XCTAssertEqual(hydrated.managedHomePath, managedHome.path)
        XCTAssertEqual(try Data(contentsOf: storeURL), storeBefore)
    }

    private static func makeStandaloneHome(root: URL, tokens: CodexTokens) throws -> URL {
        let homes = root.appendingPathComponent(CodexLoginLauncher.standaloneHomesDirectoryName, isDirectory: true)
        let home = homes.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: homes.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: home.path)
        try CodexAuth.write(tokens, to: home.appendingPathComponent("auth.json"))
        try Data("completed\n".utf8).write(to: home.appendingPathComponent(CodexLoginLauncher.successMarkerName))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: home.appendingPathComponent(CodexLoginLauncher.successMarkerName).path)
        return home
    }

    func testGenericUpsertDoesNotClearNeedsLoginWithoutUsageVerification() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("managed-source-generic-upsert-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let source = AccountCredentialSource(
            kind: .nativeAuth,
            path: root.appendingPathComponent("auth.json").path
        )
        let accountID = "native-account"
        let storedTokens = Self.tokens("stored", expiry: Date().addingTimeInterval(60), accountID: accountID)
        let incomingTokens = Self.tokens("incoming", expiry: Date().addingTimeInterval(600), accountID: accountID)
        let store = AccountStore(url: root.appendingPathComponent("accounts.json"))
        await store.upsert(Account(
            alias: "native",
            accountID: accountID,
            accessToken: storedTokens.accessToken,
            refreshToken: storedTokens.refreshToken,
            idToken: storedTokens.idToken,
            needsLogin: true,
            credentialSource: source
        ))

        let merged = await store.upsert(Account(
            alias: "new-label",
            accountID: accountID,
            accessToken: incomingTokens.accessToken,
            refreshToken: incomingTokens.refreshToken,
            idToken: incomingTokens.idToken,
            credentialSource: source
        ))

        XCTAssertEqual(merged.alias, "native")
        XCTAssertEqual(merged.accessToken, incomingTokens.accessToken)
        XCTAssertEqual(merged.refreshToken, incomingTokens.refreshToken)
        XCTAssertEqual(merged.idToken, incomingTokens.idToken)
        XCTAssertEqual(merged.credentialSource, source)
        XCTAssertTrue(merged.needsLogin)
    }

    private static func tokens(_ label: String, expiry: Date, accountID: String) -> CodexTokens {
        CodexTokens(
            idToken: "id-\(label)",
            accessToken: jwt(label, expiry: expiry, accountID: accountID),
            refreshToken: "refresh-\(label)",
            accountId: accountID
        )
    }

    func testTrustedManagedRotationAcceptsLowerExpiryButGenericImportCannotMoveOwner() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("managed-lower-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AccountStore(url: root.appendingPathComponent("accounts.json"))
        let old = Self.tokens("old", expiry: Date().addingTimeInterval(3600), accountID: "account")
        let new = Self.tokens("new", expiry: Date().addingTimeInterval(600), accountID: "account")
        let existing = AccountImporter.account(from: old, aliasHint: "managed", managedHomePath: root.appendingPathComponent("old").path)
        await store.upsert(existing)
        await store.markNeedsLoginOnly("managed")
        let incoming = AccountImporter.account(from: new, managedHomePath: root.appendingPathComponent("new").path)
        let generic = await store.upsert(incoming)
        XCTAssertEqual(generic.managedHomePath, existing.managedHomePath)
        XCTAssertEqual(generic.accessToken, old.accessToken)
        let trusted = await store.reconcileManagedAccount(incoming)
        XCTAssertEqual(trusted.managedHomePath, incoming.managedHomePath)
        XCTAssertEqual(trusted.accessToken, new.accessToken)
        XCTAssertTrue(trusted.needsLogin)
    }

    func testManagedImporterUsesSelectedWorkspaceWhenTokenNamesDifferentDefaultWorkspace() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("managed-selected-workspace-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try CodexAuth.write(Self.tokens("default", expiry: Date().addingTimeInterval(600), accountID: "default-workspace"),
                            to: root.appendingPathComponent("auth.json"))
        let imported = AccountImporter.codexBarAccounts([
            CodexBarBridge.ManagedAccount(email: "", accountID: "selected-workspace", managedHomePath: root.path)
        ])

        XCTAssertEqual(imported.count, 1)
        XCTAssertEqual(imported.first?.accountID, "selected-workspace")
        XCTAssertEqual(imported.first?.managedHomePath, root.path)
    }

    func testManagedImporterRejectsInternallyInconsistentTokenIdentity() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("managed-token-mismatch-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        var tokens = Self.tokens("wrong", expiry: Date().addingTimeInterval(600), accountID: "jwt-workspace")
        tokens.accountId = "auth-file-workspace"
        try CodexAuth.write(tokens, to: root.appendingPathComponent("auth.json"))
        let imported = AccountImporter.codexBarAccounts([
            CodexBarBridge.ManagedAccount(email: "", accountID: "selected-workspace", managedHomePath: root.path)
        ])

        XCTAssertTrue(imported.isEmpty)
    }

    func testManagedHydrationPreservesSelectedWorkspaceAcrossDefaultTokenRotation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("managed-workspace-hydration-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home", isDirectory: true)
        let oldTokens = Self.tokens("old", expiry: Date().addingTimeInterval(60), accountID: "default-workspace")
        let newTokens = Self.tokens("new", expiry: Date().addingTimeInterval(600), accountID: "default-workspace")
        try CodexAuth.write(newTokens, to: home.appendingPathComponent("auth.json"))
        let store = AccountStore(url: root.appendingPathComponent("accounts.json"))
        await store.upsert(Account(
            alias: "managed",
            accountID: "selected-workspace",
            accessToken: oldTokens.accessToken,
            refreshToken: oldTokens.refreshToken,
            idToken: oldTokens.idToken,
            managedHomePath: home.path,
            credentialSource: AccountCredentialSource(kind: .managedHome, path: home.path)
        ))

        let hydrated = await store.hydrateFromManagedHome("managed")

        XCTAssertEqual(hydrated?.accountID, "selected-workspace")
        XCTAssertEqual(hydrated?.accessToken, newTokens.accessToken)
        XCTAssertEqual(hydrated?.refreshToken, newTokens.refreshToken)
    }

    func testManagedRecoveryUsesSelectedWorkspaceWithoutChangingCredentialOwner() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("managed-workspace-recovery-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home", isDirectory: true)
        let oldTokens = Self.tokens("old", expiry: Date().addingTimeInterval(60), accountID: "default-workspace")
        let newTokens = Self.tokens("new", expiry: Date().addingTimeInterval(600), accountID: "default-workspace")
        try CodexAuth.write(newTokens, to: home.appendingPathComponent("auth.json"))
        let current = Account(
            alias: "managed",
            accountID: "selected-workspace",
            accessToken: oldTokens.accessToken,
            refreshToken: oldTokens.refreshToken,
            idToken: oldTokens.idToken,
            needsLogin: true,
            managedHomePath: home.path
        )

        let candidate = try XCTUnwrap(AuthenticationRecovery.candidate(for: current))

        XCTAssertEqual(candidate.accountID, "selected-workspace")
        XCTAssertEqual(candidate.credentialAccountID, "default-workspace")
        XCTAssertTrue(AuthenticationRecovery.accepts(candidate, for: current))
    }

    func testWorkspacePrecedenceMigrationReplacesRetiredManagedIdentityWithoutAliasSuffix() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("managed-workspace-migration-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home", isDirectory: true)
        let tokens = Self.tokens("managed", expiry: Date().addingTimeInterval(600), accountID: "default-workspace")
        try CodexAuth.write(tokens, to: home.appendingPathComponent("auth.json"))
        let store = AccountStore(url: root.appendingPathComponent("accounts.json"))
        let usage = [UsageWindow(label: "Weekly", usedPercent: 44, windowSeconds: 604_800, resetAt: nil)]
        let disabledUntil = Date().addingTimeInterval(3_600)
        let lastUsedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let lastServedByUs = Date(timeIntervalSince1970: 1_700_000_100)
        let usageStats = UsageStats(totalRequests: 4, inputTokens: 120, outputTokens: 80)
        let usageHistory = [WindowSample(capturedAt: lastServedByUs, label: "Weekly", usedPercent: 44)]
        let telemetryID = UUID()
        let usageLimitSettings = AccountUsageLimitSettings(enabled: true, fiveHourPercent: 42, weeklyPercent: 73)
        var existingAccount = Account(
            alias: "alyy2",
            accountID: "legacy-provider-workspace",
            accessToken: tokens.accessToken,
            refreshToken: tokens.refreshToken,
            idToken: tokens.idToken,
            disabledUntil: ["quota": disabledUntil],
            lastUsedAt: lastUsedAt,
            usage: usage,
            managedHomePath: home.path,
            telemetryID: telemetryID,
            usageLimitSettings: usageLimitSettings
        )
        existingAccount.usageStats = usageStats
        existingAccount.usageHistory = usageHistory
        existingAccount.lastServedByUs = lastServedByUs
        await store.upsert(existingAccount)
        _ = await store.setActive("alyy2", now: lastUsedAt)
        let stickyEnabled = await store.toggleStickyAlias("alyy2", now: lastUsedAt)
        XCTAssertTrue(stickyEnabled)
        let incoming = try XCTUnwrap(AccountImporter.codexBarAccounts([
            CodexBarBridge.ManagedAccount(
                email: "alyy2@example.com",
                accountID: "selected-workspace",
                managedHomePath: home.path
            )
        ]).first)

        let migrated = await store.reconcileManagedAccount(
            incoming,
            presentAccountIDs: ["selected-workspace"]
        )
        let removal = await store.reconcileManagedWithTelemetry(present: ["selected-workspace"])

        XCTAssertEqual(migrated.alias, "alyy2")
        XCTAssertEqual(migrated.accountID, "selected-workspace")
        XCTAssertEqual(migrated.credentialAccountID, "default-workspace")
        XCTAssertTrue(migrated.needsLogin)
        XCTAssertTrue(migrated.usage.isEmpty)
        XCTAssertTrue(migrated.disabledUntil.isEmpty)
        XCTAssertNil(migrated.usageStats)
        XCTAssertNil(migrated.usageHistory)
        XCTAssertNil(migrated.lastServedByUs)
        XCTAssertNil(migrated.lastUsedAt)
        XCTAssertEqual(migrated.priority, 1)
        XCTAssertTrue(migrated.routingEnabled)
        XCTAssertEqual(migrated.telemetryID, telemetryID)
        XCTAssertEqual(migrated.usageLimitSettings, usageLimitSettings)
        let activeAlias = await store.activeAlias()
        let stickyAlias = await store.stickyAlias()
        XCTAssertEqual(activeAlias, "alyy2")
        XCTAssertEqual(stickyAlias, "alyy2")
        XCTAssertTrue(removal.removedAliases.isEmpty)
        let aliases = await store.all().map(\.alias)
        XCTAssertEqual(aliases, ["alyy2"])
    }

    private static func jwt(_ label: String, expiry: Date, accountID: String) -> String {
        let payload = try! JSONSerialization.data(withJSONObject: [
            "exp": Int(expiry.timeIntervalSince1970),
            "account_id": accountID,
            "jti": label
        ])
        let encoded = payload
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "e30.\(encoded).sig"
    }
}

private struct LegacyCredentialSourceFixture: Codable {
    let kind: AccountCredentialSource.Kind
    let path: String?
}
