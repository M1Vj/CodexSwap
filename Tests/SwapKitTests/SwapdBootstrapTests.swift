import CryptoKit
import Foundation
import XCTest
@testable import SwapKit

final class SwapdBootstrapTests: XCTestCase {
    func testUsageLimitDryRunSkipsBootstrapArchiving() {
        let arguments = [
            "agent", "account", "usage-limit", "set", "paused",
            "--five-hour", "80", "--weekly", "90", "--enable", "--dry-run", "--json",
        ]

        XCTAssertTrue(SwapdBootstrap.isUsageLimitDryRun(arguments: arguments))
        XCTAssertFalse(SwapdBootstrap.shouldArchiveDueAccounts(arguments: arguments))
    }

    func testUsageLimitDryRunWithLeadingGlobalFlagsSkipsBootstrapArchiving() {
        let arguments = [
            "agent", "--dry-run", "account", "usage-limit", "set", "paused",
            "--five-hour", "80", "--weekly", "90", "--enable", "--json",
        ]

        XCTAssertTrue(SwapdBootstrap.isUsageLimitDryRun(arguments: arguments))
        XCTAssertFalse(SwapdBootstrap.shouldArchiveDueAccounts(arguments: arguments))
    }

    func testUsageLimitDryRunWithInterleavedGlobalFlagsSkipsBootstrapArchiving() {
        let arguments = [
            "agent", "account", "--json", "usage-limit", "set", "paused",
            "--five-hour", "80", "--dry-run", "--weekly", "90", "--enable",
        ]

        XCTAssertTrue(SwapdBootstrap.isUsageLimitDryRun(arguments: arguments))
        XCTAssertFalse(SwapdBootstrap.shouldArchiveDueAccounts(arguments: arguments))
    }

    func testNormalUsageLimitSetRetainsBootstrapArchiving() {
        let arguments = [
            "agent", "account", "usage-limit", "set", "paused",
            "--five-hour", "80", "--weekly", "90", "--enable", "--json",
        ]

        XCTAssertFalse(SwapdBootstrap.isUsageLimitDryRun(arguments: arguments))
        XCTAssertTrue(SwapdBootstrap.shouldArchiveDueAccounts(arguments: arguments))
    }

    func testOtherDryRunCommandsRetainBootstrapArchiving() {
        let arguments = ["agent", "account", "remove", "paused", "--dry-run", "--json"]

        XCTAssertFalse(SwapdBootstrap.isUsageLimitDryRun(arguments: arguments))
        XCTAssertTrue(SwapdBootstrap.shouldArchiveDueAccounts(arguments: arguments))
    }

    func testMalformedUsageLimitDryRunRetainsBootstrapArchiving() {
        let missingTarget = ["agent", "--dry-run", "account", "usage-limit", "set"]
        let unknownFlag = [
            "agent", "account", "usage-limit", "set", "paused", "--dry-run", "--unknown",
        ]

        XCTAssertFalse(SwapdBootstrap.isUsageLimitDryRun(arguments: missingTarget))
        XCTAssertTrue(SwapdBootstrap.shouldArchiveDueAccounts(arguments: missingTarget))
        XCTAssertFalse(SwapdBootstrap.isUsageLimitDryRun(arguments: unknownFlag))
        XCTAssertTrue(SwapdBootstrap.shouldArchiveDueAccounts(arguments: unknownFlag))
    }

    func testUsageLimitDryRunLeavesDuePausedAccountBytesUnchanged() throws {
        try assertDryRunLeavesDuePausedAccountBytesUnchanged(arguments: [
            "agent", "account", "usage-limit", "set", "paused",
            "--five-hour", "80", "--weekly", "90", "--enable", "--dry-run", "--json",
        ])
    }

    func testLeadingGlobalFlagsLeaveDuePausedAccountBytesUnchanged() throws {
        try assertDryRunLeavesDuePausedAccountBytesUnchanged(arguments: [
            "agent", "--dry-run", "account", "usage-limit", "set", "paused",
            "--five-hour", "80", "--weekly", "90", "--enable", "--json",
        ])
    }

    func testInterleavedGlobalFlagsLeaveDuePausedAccountBytesUnchanged() throws {
        try assertDryRunLeavesDuePausedAccountBytesUnchanged(arguments: [
            "agent", "account", "--json", "usage-limit", "set", "paused",
            "--five-hour", "80", "--dry-run", "--weekly", "90", "--enable",
        ])
    }

    private func assertDryRunLeavesDuePausedAccountBytesUnchanged(arguments: [String]) throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("swapd-dry-run-" + UUID().uuidString, isDirectory: true)
        let supportDir = home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("CodexSwap", isDirectory: true)
        try FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let paused = Account(
            alias: "paused",
            accountID: "account-local",
            accessToken: "token",
            priority: 1,
            routingEnabled: false,
            routingPausedAt: Date(timeIntervalSinceNow: -(AccountStore.automaticArchiveDelay + 1))
        )
        let seed = StoreData(schemaVersion: 2, accounts: [paused])
        let storeURL = supportDir.appendingPathComponent("accounts.json")
        let before = try JSONEncoder.codex.encode(seed)
        try before.write(to: storeURL, options: .atomic)
        let beforeHash = SHA256.hash(data: before)

        let process = Process()
        process.executableURL = try swapdExecutable()
        process.currentDirectoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        process.arguments = arguments
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        var environment = ProcessInfo.processInfo.environment
        environment["CFFIXED_USER_HOME"] = home.path
        environment["HOME"] = home.path
        environment["CODEX_HOME"] = home.appendingPathComponent(".codex", isDirectory: true).path
        process.environment = environment

        try process.run()
        process.waitUntilExit()

        let stdout = output.fileHandleForReading.readDataToEndOfFile()
        let stderr = error.fileHandleForReading.readDataToEndOfFile()
        XCTAssertEqual(
            process.terminationStatus,
            0,
            "swapd dry-run failed: \(String(decoding: stderr, as: UTF8.self))"
        )
        let envelope = try JSONDecoder().decode(AgentCLIEnvelope.self, from: stdout)
        XCTAssertTrue(envelope.ok)
        XCTAssertEqual(envelope.command, "agent account usage-limit set")

        let after = try Data(contentsOf: storeURL)
        XCTAssertEqual(SHA256.hash(data: after), beforeHash)
        XCTAssertEqual(after, before)
    }

    private func swapdExecutable() throws -> URL {
        let currentDirectory = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        ).standardizedFileURL
        let configuredPath = ProcessInfo.processInfo.environment["CODEXSWAP_SWAPD_TEST_EXECUTABLE"]
        let executablePath = configuredPath.flatMap { $0.isEmpty ? nil : $0 }
            ?? ".build/debug/swapd"
        let executable = URL(fileURLWithPath: executablePath, relativeTo: currentDirectory).standardizedFileURL
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw NSError(
                domain: "SwapdBootstrapTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "swapd test executable is not executable: \(executable.path)"]
            )
        }
        return executable
    }
}
