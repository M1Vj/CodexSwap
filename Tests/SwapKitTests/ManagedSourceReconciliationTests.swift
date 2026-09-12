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
