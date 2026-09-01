import XCTest
@testable import SwapKit

final class CodexLoginLauncherTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDown() {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
        super.tearDown()
    }

    func testCommandScriptQuotesCodexPathAndRunsLoginWithoutAppleEvents() {
        let path = "/Users/vj mabansag/O'Reilly/bin/codex"

        let script = CodexLoginLauncher.commandScript(codexPath: path)

        XCTAssertTrue(script.hasPrefix("#!/usr/bin/env bash\n"))
        XCTAssertTrue(script.contains("'/Users/vj mabansag/O'\\''Reilly/bin/codex' login"))
        XCTAssertFalse(script.localizedCaseInsensitiveContains("osascript"))
        XCTAssertFalse(script.localizedCaseInsensitiveContains("tell application"))
    }

    func testWriteCommandFileCreatesExecutableCommandFile() throws {
        let directory = try makeTemporaryDirectory()

        let url = try CodexLoginLauncher.writeCommandFile(
            codexPath: "/opt/homebrew/bin/codex",
            directory: directory,
            identifier: "test-login"
        )

        XCTAssertEqual(url.pathExtension, "command")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), CodexLoginLauncher.commandScript(codexPath: "/opt/homebrew/bin/codex"))
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue & 0o777
        XCTAssertEqual(permissions, 0o755)
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        let directoryPermissions = try XCTUnwrap(directoryAttributes[.posixPermissions] as? NSNumber).intValue & 0o777
        XCTAssertEqual(directoryPermissions, 0o700)
    }

    func testCommandScriptPassesBashSyntaxCheck() throws {
        let directory = try makeTemporaryDirectory()
        let url = try CodexLoginLauncher.writeCommandFile(
            codexPath: "/opt/homebrew/bin/codex",
            directory: directory,
            identifier: "syntax-check"
        )
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-n", url.path]

        try process.run()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0)
    }

    func testCommandFileInvokesBinaryWithLoginAndRemovesItself() throws {
        let directory = try makeTemporaryDirectory()
        let marker = directory.appendingPathComponent("login arguments")
        let fakeCodex = directory.appendingPathComponent("fake codex")
        let fakeScript = "#!/usr/bin/env bash\nprintf '%s\\n' \"$*\" > \"\(marker.path)\"\n"
        try Data(fakeScript.utf8).write(to: fakeCodex)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeCodex.path)
        let commandFile = try CodexLoginLauncher.writeCommandFile(
            codexPath: fakeCodex.path,
            directory: directory,
            identifier: "exec-check"
        )
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [commandFile.path]
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        try process.run()
        input.fileHandleForWriting.write(Data("\n".utf8))
        input.fileHandleForWriting.closeFile()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "login\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: commandFile.path))
    }

    func testTerminalOpenFailureProvidesManualFallbackWithoutAutomationPermissionGuidance() {
        let path = "~/Library/Application Support/CodexSwap/codex-login-test.command"

        let message = CodexLoginLaunchError.terminalOpenFailed(path: path).userMessage

        XCTAssertTrue(message.contains("Double-click"))
        XCTAssertTrue(message.contains(path))
        XCTAssertFalse(message.localizedCaseInsensitiveContains("Automation"))
        XCTAssertFalse(message.localizedCaseInsensitiveContains("Privacy & Security"))
    }

    func testMissingBinaryMessageRemainsActionable() {
        let message = CodexLoginLaunchError.binaryNotFound.userMessage

        XCTAssertTrue(message.contains("Codex executable not found"))
        XCTAssertTrue(message.contains("Install the Codex CLI"))
    }

    func testCommandFileWriteFailureIncludesOnlyTheExactFallbackPath() throws {
        let directory = try makeTemporaryDirectory()
        let blocker = directory.appendingPathComponent("blocked")
        XCTAssertTrue(FileManager.default.createFile(atPath: blocker.path, contents: Data()))

        XCTAssertThrowsError(
            try CodexLoginLauncher.writeCommandFile(
                codexPath: "/opt/homebrew/bin/codex",
                directory: blocker,
                identifier: "test-login"
            )
        ) { error in
            guard case let CodexLoginLaunchError.commandFileWriteFailed(path) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertTrue(path.hasPrefix(blocker.path))
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-login-launcher-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory
    }
}
