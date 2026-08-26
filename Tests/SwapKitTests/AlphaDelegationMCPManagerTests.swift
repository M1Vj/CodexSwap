import Foundation
import XCTest
@testable import SwapKit

final class AlphaDelegationMCPManagerTests: XCTestCase {
    private actor RecordingRunner: CodexCommandRunning {
        private var responses: [Result<CodexCommandResult, CodexCommandError>]
        private(set) var calls: [[String]] = []
        private(set) var timeouts: [Duration] = []
        private(set) var outputLimits: [Int] = []

        init(_ responses: [Result<CodexCommandResult, CodexCommandError>]) {
            self.responses = responses
        }

        func run(
            arguments: [String],
            timeout: Duration,
            maxOutputBytes: Int
        ) async throws -> CodexCommandResult {
            calls.append(arguments)
            timeouts.append(timeout)
            outputLimits.append(maxOutputBytes)
            guard !responses.isEmpty else {
                throw CodexCommandError.launchFailed
            }
            return try responses.removeFirst().get()
        }
    }

    private var helperURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        helperURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexSwap Alpha Helper " + UUID().uuidString, isDirectory: false)
        try Data("helper".utf8).write(to: helperURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helperURL.path)
    }

    override func tearDownWithError() throws {
        if let helperURL { try? FileManager.default.removeItem(at: helperURL) }
        try super.tearDownWithError()
    }

    func testStatusUsesExactListArgumentsAndReportsInstalledForOwnedIdentity() async throws {
        let runner = RecordingRunner([.success(.init(stdout: Data(installedListJSON(for: helperURL).utf8), exitCode: 0))])
        let manager = makeManager(runner: runner)

        let status = await manager.status()

        XCTAssertEqual(status, .installed)
        let calls = await runner.calls
        let timeouts = await runner.timeouts
        let outputLimits = await runner.outputLimits
        XCTAssertEqual(calls, [["mcp", "list", "--json"]])
        XCTAssertLessThanOrEqual(timeouts[0], .seconds(15))
        XCTAssertLessThanOrEqual(outputLimits[0], 128 * 1024)
    }

    func testStatusIgnoresWellFormedNonStdioEntriesInTheCodexList() async throws {
        let list = "[{\"name\":\"remote\",\"enabled\":true,\"transport\":{\"type\":\"streamable_http\",\"url\":\"https://example.invalid/mcp\"}},"
            + installedJSON(for: helperURL)
            + "]"
        let runner = RecordingRunner([.success(.init(stdout: Data(list.utf8), exitCode: 0))])
        let manager = makeManager(runner: runner)

        let status = await manager.status()
        XCTAssertEqual(status, .installed)
    }

    func testNotInstalledStatusNeverInvokesAddOrRemove() async throws {
        let runner = RecordingRunner([
            .success(.init(stdout: Data("[]".utf8), exitCode: 0)),
        ])
        let manager = makeManager(runner: runner)

        let status = await manager.status()
        XCTAssertEqual(status, .notInstalled)

        let calls = await runner.calls
        XCTAssertEqual(calls, [["mcp", "list", "--json"]])
        XCTAssertTrue(calls.allSatisfy { !$0.contains("add") && !$0.contains("remove") })
    }

    func testStatusNeverRunsARemovalCommand() async throws {
        let runner = RecordingRunner([
            .success(.init(stdout: Data(installedListJSON(for: helperURL).utf8), exitCode: 0)),
        ])
        let manager = makeManager(runner: runner)

        let status = await manager.status()
        XCTAssertEqual(status, .installed)

        let calls = await runner.calls
        XCTAssertEqual(calls, [["mcp", "list", "--json"]])
        XCTAssertTrue(calls.allSatisfy { !$0.contains("remove") })
    }

    func testInstallGuidanceIsAvailableOnlyAfterFreshNotInstalledStatus() async throws {
        let runner = RecordingRunner([
            .success(.init(stdout: Data("[]".utf8), exitCode: 0)),
        ])
        let manager = makeManager(runner: runner)

        let guidance = await manager.installGuidance()

        XCTAssertNotNil(guidance)
        XCTAssertTrue(guidance?.contains("mcp list --json") == true)
        let quotedPath = "'" + helperURL.path + "'"
        XCTAssertTrue(guidance?.contains("mcp add codexswap_alpha -- " + quotedPath) == true)
        let calls = await runner.calls
        XCTAssertEqual(calls, [["mcp", "list", "--json"]])
    }

    func testInstallGuidanceShellQuotesSpacesAndApostrophes() async throws {
        let quotedHelper = helperURL.deletingLastPathComponent()
            .appendingPathComponent("CodexSwap Alpha ' Helper " + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: quotedHelper) }
        try Data("helper".utf8).write(to: quotedHelper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: quotedHelper.path)

        let runner = RecordingRunner([
            .success(.init(stdout: Data("[]".utf8), exitCode: 0)),
        ])
        let manager = AlphaDelegationMCPManager(
            codexBinary: URL(fileURLWithPath: "/usr/bin/codex"),
            bundledExecutableURL: quotedHelper,
            runner: runner
        )

        let guidance = await manager.installGuidance()

        let quotedPath = "'" + quotedHelper.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        XCTAssertTrue(guidance?.contains("mcp add codexswap_alpha -- " + quotedPath) == true)
    }

    func testIdentityMismatchIsConflictAndNeverRemovesAnotherServer() async throws {
        let other = "/tmp/another-owner/codexswap-alpha-mcp"
        let runner = RecordingRunner([
            .success(.init(stdout: Data(installedListJSON(for: URL(fileURLWithPath: other)).utf8), exitCode: 0)),
        ])
        let manager = makeManager(runner: runner)

        let status = await manager.status()
        XCTAssertEqual(status, .conflict(message: "A different MCP registration already owns codexswap_alpha; it was left untouched."))

        let calls = await runner.calls
        XCTAssertEqual(calls, [["mcp", "list", "--json"]])
    }

    func testDisableGuidanceRequiresFreshIdentityCheckBeforeManualRemoval() {
        XCTAssertTrue(AlphaDelegationMCPManager.disableGuidance.contains("mcp get codexswap_alpha --json"))
        XCTAssertTrue(AlphaDelegationMCPManager.disableGuidance.contains("matches the bundled helper's absolute path"))
        XCTAssertTrue(AlphaDelegationMCPManager.disableGuidance.contains("mcp remove codexswap_alpha"))
    }

    func testInstallGuidanceStaysHiddenForOwnershipConflict() async throws {
        let other = URL(fileURLWithPath: "/tmp/another-owner/codexswap-alpha-mcp")
        let runner = RecordingRunner([
            .success(.init(stdout: Data(installedListJSON(for: other).utf8), exitCode: 0)),
        ])
        let manager = makeManager(runner: runner)

        let guidance = await manager.installGuidance()

        XCTAssertNil(guidance)
    }

    func testInstallGuidanceStaysHiddenWhenAlreadyInstalled() async throws {
        let runner = RecordingRunner([
            .success(.init(stdout: Data(installedListJSON(for: helperURL).utf8), exitCode: 0)),
        ])
        let manager = makeManager(runner: runner)

        let guidance = await manager.installGuidance()

        XCTAssertNil(guidance)
    }

    func testNonEmptyArgsOrEnvironmentAreNotOwned() async throws {
        let json = """
        [{"name":"codexswap_alpha","enabled":true,"transport":{"type":"stdio","command":"\(jsonEscape(helperURL.path))","args":["unexpected"],"env":{"TOKEN":"redacted"},"env_vars":[],"cwd":null}}]
        """
        let runner = RecordingRunner([.success(.init(stdout: Data(json.utf8), exitCode: 0))])
        let manager = makeManager(runner: runner)

        let status = await manager.status()

        guard case .conflict = status else {
            return XCTFail("Expected a fail-closed conflict")
        }
    }

    func testBundledExecutableSymlinkIsUnavailableAndNeverRegistered() async throws {
        let symlinkURL = helperURL.deletingLastPathComponent()
            .appendingPathComponent("CodexSwap Alpha Helper Alias " + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: symlinkURL) }
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: helperURL)

        let runner = RecordingRunner([])
        let manager = AlphaDelegationMCPManager(
            codexBinary: URL(fileURLWithPath: "/usr/bin/codex"),
            bundledExecutableURL: symlinkURL,
            runner: runner
        )

        guard case .unavailable = await manager.status() else {
            return XCTFail("A symlinked helper must fail closed")
        }
        let calls = await runner.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testMalformedJSONIsUnavailableWithoutAnyMutation() async throws {
        let runner = RecordingRunner([.success(.init(stdout: Data("not-json".utf8), exitCode: 0))])
        let manager = makeManager(runner: runner)

        guard case .unavailable(let message) = await manager.status() else {
            return XCTFail("Expected unavailable status")
        }
        XCTAssertFalse(message.contains("not-json"))
        let calls = await runner.calls
        XCTAssertEqual(calls.count, 1)
    }

    func testOversizedCombinedOutputIsUnavailableAndBounded() async throws {
        let runner = RecordingRunner([.success(.init(
            stdout: Data(repeating: 0x7B, count: AlphaDelegationMCPManager.maximumOutputBytes),
            stderr: Data("warning".utf8),
            exitCode: 0
        ))])
        let manager = makeManager(runner: runner)

        guard case .unavailable = await manager.status() else {
            return XCTFail("Expected unavailable status")
        }
        let outputLimits = await runner.outputLimits
        XCTAssertEqual(outputLimits, [AlphaDelegationMCPManager.maximumOutputBytes])
    }

    func testMissingCodexBinaryIsUnavailableAndDoesNotAttemptRegistration() async throws {
        let runner = RecordingRunner([.failure(.binaryMissing)])
        let manager = AlphaDelegationMCPManager(
            codexBinary: nil,
            bundledExecutableURL: helperURL,
            runner: runner
        )

        guard case .unavailable(let message) = await manager.status() else {
            return XCTFail("Expected unavailable status")
        }
        XCTAssertTrue(message.contains("Codex"))
        let calls = await runner.calls
        XCTAssertEqual(calls, [["mcp", "list", "--json"]])
    }

    func testUnexpectedListFailureIsUnavailableInsteadOfPretendingServerIsAbsent() async throws {
        let runner = RecordingRunner([.failure(.nonZeroExit(status: 2))])
        let manager = makeManager(runner: runner)

        guard case .unavailable = await manager.status() else {
            return XCTFail("Unexpected command failures must not be treated as an absent server")
        }
    }

    func testStatusReadsFreshResponseEachTimeInsteadOfCaching() async throws {
        let runner = RecordingRunner([
            .success(.init(stdout: Data(installedListJSON(for: helperURL).utf8), exitCode: 0)),
            .success(.init(stdout: Data("[]".utf8), exitCode: 0)),
        ])
        let manager = makeManager(runner: runner)

        let firstStatus = await manager.status()
        let secondStatus = await manager.status()
        let calls = await runner.calls
        XCTAssertEqual(firstStatus, .installed)
        XCTAssertEqual(secondStatus, .notInstalled)
        XCTAssertEqual(calls.count, 2)
    }

    private func makeManager(runner: RecordingRunner) -> AlphaDelegationMCPManager {
        AlphaDelegationMCPManager(
            codexBinary: URL(fileURLWithPath: "/usr/bin/codex"),
            bundledExecutableURL: helperURL,
            runner: runner
        )
    }

    private func installedJSON(for executable: URL) -> String {
        """
        {"name":"codexswap_alpha","enabled":true,"transport":{"type":"stdio","command":"\(jsonEscape(executable.path))","args":[],"env":null,"env_vars":[],"cwd":null}}
        """
    }

    private func installedListJSON(for executable: URL) -> String {
        "[" + installedJSON(for: executable) + "]"
    }

    private func jsonEscape(_ value: String) -> String {
        let data = try! JSONEncoder().encode(value)
        return String(decoding: data.dropFirst().dropLast(), as: UTF8.self)
    }
}
