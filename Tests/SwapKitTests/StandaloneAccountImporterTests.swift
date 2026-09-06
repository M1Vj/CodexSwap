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

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("standalone-importer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
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
