import Foundation
import XCTest
@testable import SwapKit

final class StandaloneAccountImporterTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDown() {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
        super.tearDown()
    }

    func testStandaloneHomesLockCanBeAcquiredForPrivateSupportDirectory() throws {
        let support = try makeTemporaryDirectory()

        let lock = try StandaloneHomesLock.acquire(supportDirectory: support)

        lock.release()
    }

    func testStandaloneHomesLockCreatesMissingPrivateSupportDirectory() throws {
        let parent = try makeTemporaryDirectory()
        let support = parent.appendingPathComponent("new-support", isDirectory: true)

        let lock = try StandaloneHomesLock.acquire(supportDirectory: support)
        lock.release()

        let attributes = try FileManager.default.attributesOfItem(atPath: support.path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue & 0o777
        XCTAssertEqual(permissions, 0o700)
    }

    func testStandaloneImporterRequiresSuccessMarkerIdentityAndNonEmptyTokens() throws {
        let support = try makeTemporaryDirectory()
        let homes = support.appendingPathComponent("standalone-homes", isDirectory: true)
        try FileManager.default.createDirectory(at: homes, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        let validHome = try makeHome(in: homes)
        try writeBundle(
            to: validHome,
            tokens: tokens(accountID: "valid", email: "valid@example.com", expiry: now.addingTimeInterval(3600)),
            marker: true
        )

        let unmarkedHome = try makeHome(in: homes)
        try writeBundle(
            to: unmarkedHome,
            tokens: tokens(accountID: "unmarked", email: "unmarked@example.com", expiry: now.addingTimeInterval(3600)),
            marker: false
        )

        let malformedHome = try makeHome(in: homes)
        _ = FileManager.default.createFile(
            atPath: malformedHome.appendingPathComponent(".codexswap-login-success").path,
            contents: Data()
        )
        try Data("not-json".utf8).write(to: malformedHome.appendingPathComponent("auth.json"))

        let targetHome = try makeTemporaryDirectory()
        try writeBundle(
            to: targetHome,
            tokens: tokens(accountID: "target", email: "target@example.com", expiry: now.addingTimeInterval(3600)),
            marker: true
        )
        let symlinkHome = homes.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createSymbolicLink(at: symlinkHome, withDestinationURL: targetHome)

        let imported = AccountImporter.standaloneCodexAuthAccounts(supportDirectory: support, now: now)

        XCTAssertEqual(imported.count, 1)
        let account = try XCTUnwrap(imported.first)
        XCTAssertEqual(account.accountID, "valid")
        XCTAssertEqual(account.credentialSource?.kind, .nativeAuth)
        XCTAssertEqual(account.credentialSource?.path, validHome.appendingPathComponent("auth.json").path)
        XCTAssertNil(account.managedHomePath)
    }

    func testStandaloneImporterChoosesNewestFutureBundleForSameAccount() throws {
        let support = try makeTemporaryDirectory()
        let homes = support.appendingPathComponent("standalone-homes", isDirectory: true)
        try FileManager.default.createDirectory(at: homes, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        let oldHome = try makeHome(in: homes)
        try writeBundle(
            to: oldHome,
            tokens: tokens(accountID: "same", email: "same@example.com", expiry: now.addingTimeInterval(600), marker: "old"),
            marker: true
        )
        let newestHome = try makeHome(in: homes)
        try writeBundle(
            to: newestHome,
            tokens: tokens(accountID: "same", email: "same@example.com", expiry: now.addingTimeInterval(3600), marker: "new"),
            marker: true
        )
        let expiredHome = try makeHome(in: homes)
        try writeBundle(
            to: expiredHome,
            tokens: tokens(accountID: "same", email: "same@example.com", expiry: now.addingTimeInterval(-60), marker: "expired"),
            marker: true
        )

        let imported = AccountImporter.standaloneCodexAuthAccounts(supportDirectory: support, now: now)

        XCTAssertEqual(imported.count, 1)
        let account = try XCTUnwrap(imported.first)
        XCTAssertEqual(account.accessToken, tokens(accountID: "same", email: "same@example.com", expiry: now.addingTimeInterval(3600), marker: "new").accessToken)
        XCTAssertEqual(account.credentialSource?.path, newestHome.appendingPathComponent("auth.json").path)
    }

    func testConfirmedRemovalQuarantinesEveryStandaloneHomeForAccountBeforeRescan() async throws {
        let support = try makeTemporaryDirectory()
        let homes = support.appendingPathComponent("standalone-homes", isDirectory: true)
        try FileManager.default.createDirectory(
            at: homes,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        let olderHome = try makeHome(in: homes)
        try writeBundle(
            to: olderHome,
            tokens: tokens(accountID: "same", email: "same@example.com", expiry: now.addingTimeInterval(600), marker: "old"),
            marker: true
        )
        let newerHome = try makeHome(in: homes)
        try writeBundle(
            to: newerHome,
            tokens: tokens(accountID: "same", email: "same@example.com", expiry: now.addingTimeInterval(3_600), marker: "new"),
            marker: true
        )
        let otherHome = try makeHome(in: homes)
        try writeBundle(
            to: otherHome,
            tokens: tokens(accountID: "other", email: "other@example.com", expiry: now.addingTimeInterval(3_600)),
            marker: true
        )

        let account = try XCTUnwrap(
            AccountImporter.standaloneCodexAuthAccounts(supportDirectory: support, now: now)
                .first(where: { $0.accountID == "same" })
        )
        let store = AccountStore(url: support.appendingPathComponent("accounts.json"))
        await store.upsert(account)
        let engine = AppEngine(store: store, supportDir: support)

        let result = await engine.removeStandaloneAccount(alias: account.alias, externalAccountIDs: [])
        let storedAfterRemoval = await store.account(account.alias)

        XCTAssertEqual(result, .removed(homeCount: 2))
        XCTAssertNil(storedAfterRemoval)
        let importedAfterRemoval = AccountImporter.standaloneCodexAuthAccounts(supportDirectory: support, now: now)
        await engine.reconcileImportedAccounts(importedAfterRemoval)
        let storedAfterRescan = await store.all()
        XCTAssertEqual(importedAfterRemoval.map(\.accountID), ["other"])
        XCTAssertNil(storedAfterRescan.first(where: { $0.accountID == "same" }))
        XCTAssertTrue(FileManager.default.fileExists(atPath: otherHome.appendingPathComponent("auth.json").path))

        let quarantine = homes.appendingPathComponent(".removed", isDirectory: true)
        let retainedHomes = try FileManager.default.contentsOfDirectory(at: quarantine, includingPropertiesForKeys: nil)
        XCTAssertEqual(retainedHomes.count, 2)
        XCTAssertTrue(retainedHomes.allSatisfy {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("auth.json").path)
        })
    }

    func testRemovalRefusesCredentialSourceOutsideCodexSwapStandaloneHomes() async throws {
        let support = try makeTemporaryDirectory()
        let externalHome = try makeTemporaryDirectory()
        let externalAuth = externalHome.appendingPathComponent("auth.json")
        try CodexAuth.write(
            tokens(accountID: "external", email: "external@example.com", expiry: .distantFuture),
            to: externalAuth
        )
        let account = AccountImporter.account(
            from: tokens(accountID: "external", email: "external@example.com", expiry: .distantFuture),
            credentialSource: AccountCredentialSource(kind: .nativeAuth, path: externalAuth.path)
        )
        let store = AccountStore(url: support.appendingPathComponent("accounts.json"))
        await store.upsert(account)
        let engine = AppEngine(store: store, supportDir: support)

        let result = await engine.removeStandaloneAccount(alias: account.alias, externalAccountIDs: [])
        let storedAfterRemoval = await store.account(account.alias)

        XCTAssertEqual(result, .externalCredentialOwner)
        XCTAssertNotNil(storedAfterRemoval)
        XCTAssertTrue(FileManager.default.fileExists(atPath: externalAuth.path))
    }

    func testRemovalRejectsSymlinkedStandaloneHomeWithoutChangingItsTarget() async throws {
        let support = try makeTemporaryDirectory()
        let homes = support.appendingPathComponent("standalone-homes", isDirectory: true)
        try FileManager.default.createDirectory(
            at: homes,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let target = try makeTemporaryDirectory()
        let accountTokens = tokens(accountID: "target", email: "target@example.com", expiry: .distantFuture)
        try writeBundle(to: target, tokens: accountTokens, marker: true)
        let linkedHome = homes.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linkedHome, withDestinationURL: target)
        let account = AccountImporter.account(
            from: accountTokens,
            credentialSource: AccountCredentialSource(
                kind: .nativeAuth,
                path: linkedHome.appendingPathComponent("auth.json").path
            )
        )
        let store = AccountStore(url: support.appendingPathComponent("accounts.json"))
        await store.upsert(account)
        let engine = AppEngine(store: store, supportDir: support)

        let result = await engine.removeStandaloneAccount(alias: account.alias, externalAccountIDs: [])
        let storedAfterRemoval = await store.account(account.alias)

        XCTAssertEqual(result, .sourceUnavailable)
        XCTAssertNotNil(storedAfterRemoval)
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.appendingPathComponent("auth.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.appendingPathComponent(".codexswap-login-success").path))
    }

    func testRemovalRefusesMatchingExternalCredentialCopyBeforeQuarantiningHomes() async throws {
        let support = try makeTemporaryDirectory()
        let homes = support.appendingPathComponent("standalone-homes", isDirectory: true)
        try FileManager.default.createDirectory(
            at: homes,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let home = try makeHome(in: homes)
        let accountTokens = tokens(accountID: "shared", email: "shared@example.com", expiry: now.addingTimeInterval(3_600))
        try writeBundle(to: home, tokens: accountTokens, marker: true)
        let account = try XCTUnwrap(
            AccountImporter.standaloneCodexAuthAccounts(supportDirectory: support, now: now).first
        )
        let store = AccountStore(url: support.appendingPathComponent("accounts.json"))
        await store.upsert(account)
        let engine = AppEngine(store: store, supportDir: support)
        let result = await engine.removeStandaloneAccount(
            alias: account.alias,
            externalAccountIDs: ["shared"]
        )
        let storedAfterRemoval = await store.all()

        XCTAssertEqual(result, .externalCredentialOwner)
        XCTAssertNotNil(storedAfterRemoval.first(where: { $0.accountID == "shared" }))
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.appendingPathComponent("auth.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: homes.appendingPathComponent(".removed").path))
    }

    func testRemovalRestoresHomesWhenExternalOwnerAppearsDuringRemoval() async throws {
        let support = try makeTemporaryDirectory()
        let homes = support.appendingPathComponent("standalone-homes", isDirectory: true)
        try FileManager.default.createDirectory(
            at: homes,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let home = try makeHome(in: homes)
        try writeBundle(
            to: home,
            tokens: tokens(accountID: "race", email: "race@example.com", expiry: now.addingTimeInterval(3_600)),
            marker: true
        )
        let account = try XCTUnwrap(
            AccountImporter.standaloneCodexAuthAccounts(supportDirectory: support, now: now).first
        )
        let store = AccountStore(url: support.appendingPathComponent("accounts.json"))
        await store.upsert(account)
        let engine = AppEngine(store: store, supportDir: support)

        let result = await engine.removeStandaloneAccount(
            alias: account.alias,
            externalAccountIDs: [],
            recheckExternalAccountIDs: { ["race"] }
        )
        let storedAfterRefusal = await store.account(account.alias)

        XCTAssertEqual(result, .externalCredentialOwner)
        XCTAssertNotNil(storedAfterRefusal)
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.appendingPathComponent("auth.json").path))
        XCTAssertEqual(
            AccountImporter.standaloneCodexAuthAccounts(supportDirectory: support, now: now).map(\.accountID),
            ["race"]
        )
    }

    func testRemovalRestoresStandaloneHomeWhenStoreWriteFails() async throws {
        let support = try makeTemporaryDirectory()
        let homes = support.appendingPathComponent("standalone-homes", isDirectory: true)
        try FileManager.default.createDirectory(
            at: homes,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let home = try makeHome(in: homes)
        try writeBundle(
            to: home,
            tokens: tokens(accountID: "durable", email: "durable@example.com", expiry: now.addingTimeInterval(3_600)),
            marker: true
        )
        let account = try XCTUnwrap(
            AccountImporter.standaloneCodexAuthAccounts(supportDirectory: support, now: now).first
        )
        let storeURL = support.appendingPathComponent("accounts.json")
        let seedStore = AccountStore(url: storeURL)
        await seedStore.upsert(account)
        let failingStore = AccountStore(
            url: storeURL,
            persistenceWriter: { _, _ in throw CocoaError(.fileWriteNoPermission) }
        )
        let engine = AppEngine(store: failingStore, supportDir: support)

        let result = await engine.removeStandaloneAccount(alias: account.alias, externalAccountIDs: [])
        let storedAfterFailure = await failingStore.account(account.alias)
        let importedAfterFailure = AccountImporter.standaloneCodexAuthAccounts(supportDirectory: support, now: now)

        XCTAssertEqual(result, .failed)
        XCTAssertNotNil(storedAfterFailure)
        XCTAssertEqual(importedAfterFailure.map(\.accountID), ["durable"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.appendingPathComponent("auth.json").path))
    }

    func testRemovalRestoresStoreAndHomeWhenPostWriteVerificationFails() async throws {
        let support = try makeTemporaryDirectory()
        let homes = support.appendingPathComponent("standalone-homes", isDirectory: true)
        try FileManager.default.createDirectory(
            at: homes,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let home = try makeHome(in: homes)
        try writeBundle(
            to: home,
            tokens: tokens(accountID: "verify", email: "verify@example.com", expiry: now.addingTimeInterval(3_600)),
            marker: true
        )
        let account = try XCTUnwrap(
            AccountImporter.standaloneCodexAuthAccounts(supportDirectory: support, now: now).first
        )
        let storeURL = support.appendingPathComponent("accounts.json")
        let seedStore = AccountStore(url: storeURL)
        await seedStore.upsert(account)
        let failingStore = AccountStore(
            url: storeURL,
            persistenceWriter: { _, target in
                try Data("corrupt".utf8).write(to: target, options: .atomic)
            }
        )
        let engine = AppEngine(store: failingStore, supportDir: support)

        let result = await engine.removeStandaloneAccount(alias: account.alias, externalAccountIDs: [])
        let reloaded = AccountStore(url: storeURL)
        let restoredAccount = await reloaded.account(account.alias)

        XCTAssertEqual(result, .failed)
        XCTAssertEqual(restoredAccount?.accountID, account.accountID)
        XCTAssertEqual(
            AccountImporter.standaloneCodexAuthAccounts(supportDirectory: support, now: now).map(\.accountID),
            ["verify"]
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.appendingPathComponent("auth.json").path))
    }

    func testAtomicRemovalRefusesAnAliasThatNowRepresentsAnotherAccount() async throws {
        let support = try makeTemporaryDirectory()
        let store = AccountStore(url: support.appendingPathComponent("accounts.json"))
        let original = Account(alias: "shared", accountID: "original", accessToken: "original-token")
        await store.upsert(original)
        _ = await store.remove("shared")
        let replacement = Account(alias: "shared", accountID: "replacement", accessToken: "replacement-token")
        await store.upsert(replacement)

        let result = await store.removeWithTelemetryAtomically(
            "shared",
            expectedTelemetryID: original.telemetryID,
            expectedAccountID: original.accountID,
            expectedCredentialSource: original.credentialSource
        )
        let retained = await store.account("shared")

        XCTAssertEqual(result, .accountChanged)
        XCTAssertEqual(retained?.accountID, "replacement")
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("standalone-importer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        temporaryDirectories.append(directory)
        return directory
    }

    private func makeHome(in homes: URL) throws -> URL {
        let home = homes.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return home
    }

    private func writeBundle(to home: URL, tokens: CodexTokens, marker: Bool) throws {
        try CodexAuth.write(tokens, to: home.appendingPathComponent("auth.json"))
        if marker {
            try Data("completed\n".utf8).write(to: home.appendingPathComponent(".codexswap-login-success"), options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: home.appendingPathComponent(".codexswap-login-success").path)
        }
    }

    private func tokens(accountID: String, email: String, expiry: Date, marker: String = "token") -> CodexTokens {
        let payload: [String: Any] = [
            "https://api.openai.com/auth_account_id": accountID,
            "https://api.openai.com/profile": ["email": email],
            "exp": expiry.timeIntervalSince1970,
        ]
        let data = try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let encoded = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
        return CodexTokens(
            idToken: "id-\(marker)",
            accessToken: "header.\(encoded).signature-\(marker)",
            refreshToken: "refresh-\(marker)",
            accountId: accountID
        )
    }
}
