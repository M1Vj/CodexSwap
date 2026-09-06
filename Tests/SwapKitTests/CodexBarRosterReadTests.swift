import XCTest
@testable import SwapKit

final class CodexBarRosterReadTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDown() {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
        super.tearDown()
    }

    func testMalformedRosterIsNotVerifiedAsEmpty() throws {
        let file = try writeRoster("{\"accounts\":[")

        let result = CodexBarBridge.readManagedAccountsSnapshot(from: file)

        XCTAssertFailure(result, equals: .malformed)
    }

    func testValidEmptyRosterIsVerifiedAsEmpty() throws {
        let file = try writeRoster("{\"accounts\":[]}")

        let result = CodexBarBridge.readManagedAccountsSnapshot(from: file)

        guard case let .success(snapshot) = result else {
            return XCTFail("expected a verified empty roster, got \(result)")
        }
        XCTAssertTrue(snapshot.accounts.isEmpty)
        XCTAssertTrue(snapshot.accountIDs.isEmpty)
    }

    func testAbsentRosterIsDistinctFromMalformedRoster() throws {
        let directory = try makeTemporaryDirectory()
        let file = directory.appendingPathComponent("missing.json")

        let result = CodexBarBridge.readManagedAccountsSnapshot(from: file)

        XCTAssertFailure(result, equals: .absent)
    }

    func testUnreadableRosterIsDistinctFromAbsentRoster() throws {
        let directory = try makeTemporaryDirectory()

        let result = CodexBarBridge.readManagedAccountsSnapshot(from: directory)

        XCTAssertFailure(result, equals: .unreadable)
    }

    func testTopLevelMissingAccountsIsRejectedSeparately() throws {
        let file = try writeRoster("{\"version\":\"3\"}")

        let result = CodexBarBridge.readManagedAccountsSnapshot(from: file)

        XCTAssertFailure(result, equals: .topLevelMissingAccounts)
    }

    func testInvalidEntryRejectsTheWholeRosterInsteadOfReturningPartialAccounts() throws {
        let file = try writeRoster(
            """
            {"accounts":[
              {"email":"valid@example.com","providerAccountID":"acc-valid","managedHomePath":"/tmp/valid"},
              {"email":"missing-home@example.com","providerAccountID":"acc-missing-home"}
            ]}
            """
        )

        let result = CodexBarBridge.readManagedAccountsSnapshot(from: file)

        XCTAssertFailure(result, equals: .invalidEntry)
    }

    func testDuplicateAccountIDsPreserveCompatibleRosterEntries() throws {
        let file = try writeRoster(
            """
            {"accounts":[
              {"providerAccountID":"acc-duplicate","managedHomePath":"/tmp/one"},
              {"providerAccountID":"acc-duplicate","managedHomePath":"/tmp/two"}
            ]}
            """
        )

        let result = CodexBarBridge.readManagedAccountsSnapshot(from: file)

        XCTAssertEqual(try result.get().accounts.count, 2)
    }

    func testDuplicateManagedHomesPreserveCompatibleRosterEntries() throws {
        let file = try writeRoster(
            """
            {"accounts":[
              {"providerAccountID":"acc-one","managedHomePath":"/tmp/shared"},
              {"providerAccountID":"acc-two","managedHomePath":"/tmp/shared"}
            ]}
            """
        )

        let result = CodexBarBridge.readManagedAccountsSnapshot(from: file)

        XCTAssertEqual(try result.get().accounts.count, 2)
    }

    func testProviderIDRetainsPrecedenceOverDifferentWorkspaceID() throws {
        let file = try writeRoster(
            """
            {"accounts":[
              {"providerAccountID":"acc-provider","workspaceAccountID":"acc-workspace","managedHomePath":"/tmp/conflict"}
            ]}
            """
        )

        let result = CodexBarBridge.readManagedAccountsSnapshot(from: file)

        XCTAssertEqual(try result.get().accountIDs, ["acc-provider"])
    }

    func testVerifiedSnapshotCapturesIDsAndAccountsFromOneRoster() throws {
        let file = try writeRoster(
            """
            {"version":"3","accounts":[
              {"email":"provider@example.com","providerAccountID":"acc-provider","managedHomePath":"/tmp/provider"},
              {"email":"workspace@example.com","workspaceAccountID":"acc-workspace","managedHomePath":"/tmp/workspace"}
            ]}
            """
        )

        let result = CodexBarBridge.readManagedAccountsSnapshot(from: file)

        guard case let .success(snapshot) = result else {
            return XCTFail("expected a verified roster, got \(result)")
        }
        XCTAssertEqual(snapshot.accounts.map(\.accountID), ["acc-provider", "acc-workspace"])
        XCTAssertEqual(snapshot.accounts.map(\.managedHomePath), ["/tmp/provider", "/tmp/workspace"])
        XCTAssertEqual(snapshot.accountIDs, ["acc-provider", "acc-workspace"])
    }

    private func XCTAssertFailure(
        _ result: Result<CodexBarBridge.ManagedAccountsSnapshot, CodexBarBridge.RosterReadError>,
        equals expected: CodexBarBridge.RosterReadError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case let .failure(error) = result else {
            return XCTFail("expected roster read failure \(expected), got \(result)", file: file, line: line)
        }
        XCTAssertEqual(error, expected, file: file, line: line)
    }

    private func writeRoster(_ json: String) throws -> URL {
        let directory = try makeTemporaryDirectory()
        let file = directory.appendingPathComponent("managed-codex-accounts.json")
        try Data(json.utf8).write(to: file, options: .atomic)
        return file
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-roster-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory
    }
}
