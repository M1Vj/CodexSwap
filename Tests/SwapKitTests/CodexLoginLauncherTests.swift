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

        let script = CodexLoginLauncher.commandScript(codexPath: path, homePath: "/private/test-home")

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
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("cli_auth_credentials_store"))
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
        let fakeScript = "#!/usr/bin/env bash\nprintf '%s\\n' \"$*\" > \"\(marker.path)\"\nprintf '{}' > \"$CODEX_HOME/auth.json\"\n"
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
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "login -c cli_auth_credentials_store=\"file\"\n")
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

    func testStandaloneLoginUsesUniquePrivateHomeAndDoesNotTouchInheritedHome() throws {
        let support = try makeTemporaryDirectory()
        let inheritedHome = support.appendingPathComponent("inherited-home", isDirectory: true)
        try FileManager.default.createDirectory(at: inheritedHome, withIntermediateDirectories: true)
        let sentinel = inheritedHome.appendingPathComponent("auth.json")
        XCTAssertTrue(FileManager.default.createFile(atPath: sentinel.path, contents: Data("keep".utf8)))
        let observedHome = support.appendingPathComponent("observed-home")
        let observedCWD = support.appendingPathComponent("observed-cwd")
        let observedArgs = support.appendingPathComponent("observed-args")
        let fakeCodex = support.appendingPathComponent("fake-codex")
        let fakeScript = """
        #!/usr/bin/env bash
        printf '%s' "${CODEX_HOME:-}" > '\(observedHome.path)'
        printf '%s' "$PWD" > '\(observedCWD.path)'
        printf '%s' "$*" > '\(observedArgs.path)'
        mkdir -p -- "$CODEX_HOME"
        printf '%s' '{"tokens":{"access_token":"access","refresh_token":"refresh","account_id":"account"}}' > "$CODEX_HOME/auth.json"
        """
        try Data(fakeScript.utf8).write(to: fakeCodex)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeCodex.path)

        let launch = try CodexLoginLauncher.prepareStandaloneLogin(
            codexPath: fakeCodex.path,
            supportDirectory: support,
            identifier: "same-login"
        )
        let second = try CodexLoginLauncher.prepareStandaloneLogin(
            codexPath: fakeCodex.path,
            supportDirectory: support,
            identifier: "same-login"
        )
        XCTAssertNotEqual(launch.homePath, second.homePath)
        XCTAssertNotEqual(launch.commandFile, second.commandFile)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [launch.commandFile.path]
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = inheritedHome.path
        process.environment = environment
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        input.fileHandleForWriting.write(Data("\n".utf8))
        input.fileHandleForWriting.closeFile()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(try String(contentsOf: observedHome, encoding: .utf8), launch.homePath.path)
        XCTAssertEqual(try String(contentsOf: observedCWD, encoding: .utf8), launch.homePath.path)
        XCTAssertEqual(try String(contentsOf: observedArgs, encoding: .utf8), "login -c cli_auth_credentials_store=\"file\"")
        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "keep")
        XCTAssertTrue(FileManager.default.fileExists(atPath: launch.successMarker.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: launch.homePath.appendingPathComponent("auth.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: launch.commandFile.path))

        let homeAttributes = try FileManager.default.attributesOfItem(atPath: launch.homePath.path)
        let homePermissions = try XCTUnwrap(homeAttributes[.posixPermissions] as? NSNumber).intValue & 0o777
        XCTAssertEqual(homePermissions, 0o700)
        let markerAttributes = try FileManager.default.attributesOfItem(atPath: launch.successMarker.path)
        let markerPermissions = try XCTUnwrap(markerAttributes[.posixPermissions] as? NSNumber).intValue & 0o777
        XCTAssertEqual(markerPermissions, 0o600)
    }

    func testFailedStandaloneLoginPreservesHomeWithoutSuccessMarker() throws {
        let support = try makeTemporaryDirectory()
        let fakeCodex = support.appendingPathComponent("fake-codex")
        let fakeScript = """
        #!/usr/bin/env bash
        mkdir -p -- "$CODEX_HOME"
        printf '%s' '{"tokens":{"access_token":"partial","refresh_token":"partial","account_id":"account"}}' > "$CODEX_HOME/auth.json"
        exit 7
        """
        try Data(fakeScript.utf8).write(to: fakeCodex)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeCodex.path)

        let launch = try CodexLoginLauncher.prepareStandaloneLogin(
            codexPath: fakeCodex.path,
            supportDirectory: support,
            identifier: "failed-login"
        )
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [launch.commandFile.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 7)
        XCTAssertTrue(FileManager.default.fileExists(atPath: launch.homePath.appendingPathComponent("auth.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: launch.successMarker.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: launch.commandFile.path))
    }

    func testSymlinkedHomesDirectoryIsRejectedWithoutChangingTargetPermissions() throws {
        let support = try makeTemporaryDirectory()
        let target = try makeTemporaryDirectory()
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
        let homes = support.appendingPathComponent(CodexLoginLauncher.standaloneHomesDirectoryName)
        try FileManager.default.createSymbolicLink(at: homes, withDestinationURL: target)

        XCTAssertThrowsError(try CodexLoginLauncher.prepareStandaloneLogin(
            codexPath: "/opt/homebrew/bin/codex", supportDirectory: support
        ))

        let attributes = try FileManager.default.attributesOfItem(atPath: target.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o755)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target.path), [])
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-login-launcher-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory
    }
}
