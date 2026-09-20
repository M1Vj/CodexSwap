import Foundation
import XCTest
@testable import SwapKit

final class SameOrgMultiUserAccountTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDown() {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
        super.tearDown()
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("same-org-test-\(UUID().uuidString)", isDirectory: true)
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

    private func writeBundle(to home: URL, tokens: CodexTokens) throws {
        try CodexAuth.write(tokens, to: home.appendingPathComponent("auth.json"))
        try Data("completed\n".utf8).write(to: home.appendingPathComponent(".codexswap-login-success"), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: home.appendingPathComponent(".codexswap-login-success").path)
    }

    private func tokens(accountID: String, email: String, userID: String? = nil, expiry: Date, marker: String = "token") -> CodexTokens {
        var authObj: [String: Any] = [
            "chatgpt_account_id": accountID,
            "chatgpt_plan_type": "plus",
        ]
        if let userID {
            authObj["chatgpt_user_id"] = userID
            authObj["user_id"] = userID
        }
        var payload: [String: Any] = [
            "https://api.openai.com/auth": authObj,
            "https://api.openai.com/auth_account_id": accountID,
            "https://api.openai.com/profile": ["email": email],
            "exp": expiry.timeIntervalSince1970,
        ]
        if let userID {
            payload["sub"] = "auth0|\(userID)"
        }
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

    func testJWTIdentityExtractsUserID() {
        let now = Date().addingTimeInterval(3600)
        let token = tokens(
            accountID: "org-tenant-1",
            email: "alice@example.com",
            userID: "user-alice-123",
            expiry: now
        )
        let identity = JWT.identity(fromAccessToken: token.accessToken)
        XCTAssertEqual(identity.accountID, "org-tenant-1")
        XCTAssertEqual(identity.email, "alice@example.com")
        XCTAssertEqual(identity.userID, "user-alice-123")
    }

    func testAccountDecodableDefaultsUserIDAndSelfHeals() throws {
        let jsonWithoutUserID = """
        {
            "alias": "test",
            "email": "test@example.com",
            "accountID": "org-1",
            "accessToken": "",
            "priority": 1
        }
        """.data(using: .utf8)!
        let account = try JSONDecoder().decode(Account.self, from: jsonWithoutUserID)
        XCTAssertEqual(account.userID, "")

        // With accessToken containing userID
        let token = tokens(accountID: "org-1", email: "test@example.com", userID: "user-auto-heal", expiry: Date().addingTimeInterval(3600))
        let jsonWithToken = """
        {
            "alias": "test",
            "email": "test@example.com",
            "accountID": "org-1",
            "accessToken": "\(token.accessToken)",
            "priority": 1
        }
        """.data(using: .utf8)!
        let healed = try JSONDecoder().decode(Account.self, from: jsonWithToken)
        XCTAssertEqual(healed.userID, "user-auto-heal")
    }

    func testStandaloneImporterPreservesMultipleAccountsInSameOrganization() throws {
        let support = try makeTemporaryDirectory()
        let homes = support.appendingPathComponent("standalone-homes", isDirectory: true)
        try FileManager.default.createDirectory(at: homes, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        let orgID = "fb88ebc3-79ae-45ff-b8b1-2313efa099b4"

        // Account 1: jobsx1f6
        let home1 = try makeHome(in: homes)
        try writeBundle(
            to: home1,
            tokens: tokens(accountID: orgID, email: "10300430+jobsx1f6@utc2eduvn.onmicrosoft.com", userID: "user-jobs", expiry: now.addingTimeInterval(3600), marker: "jobs")
        )

        // Account 2: enquirieslbag
        let home2 = try makeHome(in: homes)
        try writeBundle(
            to: home2,
            tokens: tokens(accountID: orgID, email: "5240841+enquirieslbag@utc2eduvn.onmicrosoft.com", userID: "user-enquiries", expiry: now.addingTimeInterval(3600), marker: "enquiries")
        )

        // Account 3: workspacevdu5
        let home3 = try makeHome(in: homes)
        try writeBundle(
            to: home3,
            tokens: tokens(accountID: orgID, email: "20237540+workspacevdu5@utc2eduvn.onmicrosoft.com", userID: "user-workspace", expiry: now.addingTimeInterval(3600), marker: "workspace")
        )

        let imported = AccountImporter.standaloneCodexAuthAccounts(supportDirectory: support, now: now)
        XCTAssertEqual(imported.count, 3)

        let emails = Set(imported.map(\.email))
        XCTAssertTrue(emails.contains("10300430+jobsx1f6@utc2eduvn.onmicrosoft.com"))
        XCTAssertTrue(emails.contains("5240841+enquirieslbag@utc2eduvn.onmicrosoft.com"))
        XCTAssertTrue(emails.contains("20237540+workspacevdu5@utc2eduvn.onmicrosoft.com"))

        let userIDs = Set(imported.map(\.userID))
        XCTAssertTrue(userIDs.contains("user-jobs"))
        XCTAssertTrue(userIDs.contains("user-enquiries"))
        XCTAssertTrue(userIDs.contains("user-workspace"))

        let aliases = Set(imported.map(\.alias))
        XCTAssertEqual(aliases.count, 3)
    }

    func testAccountStoreUpsertPreservesMultipleAccountsInSameOrganization() async throws {
        let support = try makeTemporaryDirectory()
        let store = AccountStore(url: support.appendingPathComponent("accounts.json"))
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let orgID = "fb88ebc3-79ae-45ff-b8b1-2313efa099b4"

        let acc1Tokens = tokens(accountID: orgID, email: "10300430+jobsx1f6@utc2eduvn.onmicrosoft.com", userID: "user-jobs", expiry: now.addingTimeInterval(3600))
        let acc1 = AccountImporter.account(from: acc1Tokens)

        let acc2Tokens = tokens(accountID: orgID, email: "5240841+enquirieslbag@utc2eduvn.onmicrosoft.com", userID: "user-enquiries", expiry: now.addingTimeInterval(3600))
        let acc2 = AccountImporter.account(from: acc2Tokens)

        let acc3Tokens = tokens(accountID: orgID, email: "20237540+workspacevdu5@utc2eduvn.onmicrosoft.com", userID: "user-workspace", expiry: now.addingTimeInterval(3600))
        let acc3 = AccountImporter.account(from: acc3Tokens)

        await store.upsert(acc1)
        await store.upsert(acc2)
        await store.upsert(acc3)

        let all = await store.all()
        XCTAssertEqual(all.count, 3)
        XCTAssertEqual(Set(all.map(\.userID)), ["user-jobs", "user-enquiries", "user-workspace"])
        XCTAssertEqual(Set(all.map(\.email)), [
            "10300430+jobsx1f6@utc2eduvn.onmicrosoft.com",
            "5240841+enquirieslbag@utc2eduvn.onmicrosoft.com",
            "20237540+workspacevdu5@utc2eduvn.onmicrosoft.com"
        ])

        // Re-upserting acc1 with newer token updates it without modifying acc2 or acc3
        let acc1RefreshedTokens = tokens(accountID: orgID, email: "10300430+jobsx1f6@utc2eduvn.onmicrosoft.com", userID: "user-jobs", expiry: now.addingTimeInterval(7200), marker: "refreshed")
        let acc1Refreshed = AccountImporter.account(from: acc1RefreshedTokens)
        await store.upsert(acc1Refreshed)

        let allAfterRefresh = await store.all()
        XCTAssertEqual(allAfterRefresh.count, 3)
        let updatedAcc1 = try XCTUnwrap(allAfterRefresh.first(where: { $0.userID == "user-jobs" }))
        XCTAssertEqual(updatedAcc1.accessToken, acc1RefreshedTokens.accessToken)
    }

    func testAccountStoreDisambiguatesAliasesForSameOrgAccountsWithCollidingAlias() async throws {
        let support = try makeTemporaryDirectory()
        let store = AccountStore(url: support.appendingPathComponent("accounts.json"))
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let orgID = "fb88ebc3-79ae-45ff-b8b1-2313efa099b4"

        let acc1Tokens = tokens(accountID: orgID, email: "collab@utc2eduvn.onmicrosoft.com", userID: "user-collab-1", expiry: now.addingTimeInterval(3600))
        let acc1 = AccountImporter.account(from: acc1Tokens, aliasHint: "collab")

        let acc2Tokens = tokens(accountID: orgID, email: "collab@utc2eduvn.onmicrosoft.com", userID: "user-collab-2", expiry: now.addingTimeInterval(3600))
        let acc2 = AccountImporter.account(from: acc2Tokens, aliasHint: "collab")

        await store.upsert(acc1)
        await store.upsert(acc2)

        let all = await store.all()
        XCTAssertEqual(all.count, 2)
        let aliases = all.map(\.alias)
        XCTAssertTrue(aliases.contains("collab"))
        XCTAssertTrue(aliases.contains("collab-2"))
    }

    func testAccountIDReturnsAliasAndDoesNotCollideForSameOrgAccounts() {
        let acc1 = Account(alias: "account-alpha", email: "alice@example.com", accountID: "shared-org-id", userID: "user-1")
        let acc2 = Account(alias: "account-beta", email: "bob@example.com", accountID: "shared-org-id", userID: "user-2")
        XCTAssertEqual(acc1.id, "account-alpha")
        XCTAssertEqual(acc2.id, "account-beta")
        XCTAssertNotEqual(acc1.id, acc2.id)
    }

    func testStandaloneAccountRemovalQuarantinesTargetAndPreservesSameOrgSibling() async throws {
        let support = try makeTemporaryDirectory()
        let homes = support.appendingPathComponent(CodexLoginLauncher.standaloneHomesDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: homes, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let orgID = "same-org-uuid"

        // Account 1 (Alice)
        let homeAlice = try makeHome(in: homes)
        let aliceTokens = tokens(
            accountID: orgID,
            email: "alice@utc2eduvn.onmicrosoft.com",
            userID: "user-alice",
            expiry: now.addingTimeInterval(3600),
            marker: "alice"
        )
        try writeBundle(to: homeAlice, tokens: aliceTokens)

        // Account 2 (Bob - sibling in same org)
        let homeBob = try makeHome(in: homes)
        let bobTokens = tokens(
            accountID: orgID,
            email: "bob@utc2eduvn.onmicrosoft.com",
            userID: "user-bob",
            expiry: now.addingTimeInterval(3600),
            marker: "bob"
        )
        try writeBundle(to: homeBob, tokens: bobTokens)

        // Import accounts
        let imported = AccountImporter.standaloneCodexAuthAccounts(supportDirectory: support, now: now)
        XCTAssertEqual(imported.count, 2)

        let store = AccountStore(url: support.appendingPathComponent("accounts.json"))
        for acc in imported {
            await store.upsert(acc)
        }
        let engine = AppEngine(store: store, supportDir: support)

        let aliceAccount = try XCTUnwrap(imported.first(where: { $0.userID == "user-alice" }))
        let bobAccount = try XCTUnwrap(imported.first(where: { $0.userID == "user-bob" }))

        // Remove Alice's account
        let result = await engine.removeStandaloneAccount(alias: aliceAccount.alias, externalAccountIDs: [])
        XCTAssertEqual(result, .removed(homeCount: 1))

        // Alice is removed from store
        let aliceInStore = await store.account(aliceAccount.alias)
        XCTAssertNil(aliceInStore)

        // Alice's home is moved to .removed quarantine
        XCTAssertFalse(FileManager.default.fileExists(atPath: homeAlice.path))
        let quarantine = homes.appendingPathComponent(".removed", isDirectory: true)
        let quarantinedEntries = try FileManager.default.contentsOfDirectory(at: quarantine, includingPropertiesForKeys: nil)
        XCTAssertEqual(quarantinedEntries.count, 1)

        // Bob's home is completely preserved and remains valid in standalone-homes!
        XCTAssertTrue(FileManager.default.fileExists(atPath: homeBob.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: homeBob.appendingPathComponent("auth.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: homeBob.appendingPathComponent(CodexLoginLauncher.successMarkerName).path))

        // Bob's account in store remains intact
        let bobInStore = await store.account(bobAccount.alias)
        XCTAssertNotNil(bobInStore)
        XCTAssertEqual(bobInStore?.userID, "user-bob")

        // Reconciling or re-importing standalone accounts only imports Bob, not Alice
        let reimported = AccountImporter.standaloneCodexAuthAccounts(supportDirectory: support, now: now)
        XCTAssertEqual(reimported.count, 1)
        XCTAssertEqual(reimported.first?.userID, "user-bob")
    }
}
