import Foundation
import XCTest
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
@testable import SwapKit

private actor ProcessRunCompletionProbe {
    private(set) var result: Result<AlphaDelegationProcessOutput, Error>?

    func complete(_ result: Result<AlphaDelegationProcessOutput, Error>) {
        self.result = result
    }
}

final class AlphaDelegationRunnerTests: XCTestCase {
    private actor RecordingProcess: AlphaDelegationProcessRunning {
        struct Invocation: Sendable {
            let executable: URL
            let arguments: [String]
            let environment: [String: String]
            let currentDirectory: URL
            let taskFile: URL?
            let taskContents: String?
            let taskPermissions: Int?
            let homeDirectory: URL?
            let homePermissions: Int?
            let configDirectory: URL?
            let configPermissions: Int?
            let directoryPermissions: [String: Int]
        }

        let output: Result<AlphaDelegationProcessOutput, Error>
        private(set) var invocation: Invocation?
        private let holdUntilCancelled: Bool

        init(
            output: Result<AlphaDelegationProcessOutput, Error>,
            holdUntilCancelled: Bool = false
        ) {
            self.output = output
            self.holdUntilCancelled = holdUntilCancelled
        }

        func run(
            executable: URL,
            arguments: [String],
            environment: [String: String],
            currentDirectory: URL,
            timeout: Duration,
            maxOutputBytes: Int
        ) async throws -> AlphaDelegationProcessOutput {
            let taskFile = arguments.last(where: { $0.hasSuffix(".task") }).map(URL.init(fileURLWithPath:))
            let taskContents = taskFile.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            let permissions = taskFile.flatMap {
                (try? FileManager.default.attributesOfItem(atPath: $0.path)[.posixPermissions] as? NSNumber)?.intValue
            }
            let homeDirectory = environment["HOME"].map(URL.init(fileURLWithPath:))
            let homePermissions = homeDirectory.flatMap {
                (try? FileManager.default.attributesOfItem(atPath: $0.path)[.posixPermissions] as? NSNumber)?.intValue
            }
            let configDirectory = environment["XDG_CONFIG_HOME"].map(URL.init(fileURLWithPath:))
            let configPermissions = configDirectory.flatMap {
                (try? FileManager.default.attributesOfItem(atPath: $0.path)[.posixPermissions] as? NSNumber)?.intValue
            }
            var directoryPermissions: [String: Int] = [:]
            for key in ["HOME", "TMPDIR", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_CACHE_HOME"] {
                guard let path = environment[key],
                      let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                      let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue else {
                    continue
                }
                directoryPermissions[key] = mode
            }
            invocation = Invocation(
                executable: executable,
                arguments: arguments,
                environment: environment,
                currentDirectory: currentDirectory,
                taskFile: taskFile,
                taskContents: taskContents,
                taskPermissions: permissions,
                homeDirectory: homeDirectory,
                homePermissions: homePermissions,
                configDirectory: configDirectory,
                configPermissions: configPermissions,
                directoryPermissions: directoryPermissions
            )

            if holdUntilCancelled {
                while !Task.isCancelled {
                    try await Task.sleep(for: .milliseconds(10))
                }
                throw CancellationError()
            }
            return try output.get()
        }

        func recordedInvocation() -> Invocation? { invocation }
    }

    private func temporaryDirectory(named name: String = "alpha-runner") throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func process(
        stdout: String,
        stderr: String = "",
        exitStatus: Int32 = 0
    ) -> RecordingProcess {
        RecordingProcess(output: .success(.init(
            stdout: Data(stdout.utf8),
            stderr: Data(stderr.utf8),
            exitStatus: exitStatus
        )))
    }

    private func assertRunnerError(
        _ expected: AlphaDelegationRunnerError,
        operation: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await operation()
            XCTFail("expected error", file: file, line: line)
        } catch let error as AlphaDelegationRunnerError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("unexpected error type", file: file, line: line)
        }
    }

    func testLaunchUsesFixedArgumentsDoesNotLeakTaskAndRemoves0600Attachment() async throws {
        let workspace = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let sentinel = "private-task-sentinel"
        let output = #"""
{"type":"session.created","sessionID":"ses-123"}
{"type":"message.part.updated","properties":{"sessionID":"ses-123","part":{"id":"part-1","type":"text","text":"done"}}}
{"type":"message.part.updated","properties":{"sessionID":"ses-123","part":{"id":"tool-1","type":"tool","tool":"read","state":{"status":"completed"}}}}
{"type":"message.part.updated","properties":{"sessionID":"ses-123","part":{"id":"tool-2","type":"tool","tool":"read","state":{"status":"completed"}}}}
"""#
        let process = process(stdout: output)
        let runner = AlphaDelegationRunner(
            opencodeURL: URL(fileURLWithPath: "/opt/homebrew/bin/opencode"),
            process: process,
            timeout: .seconds(2),
            environment: [
                "HOME": "/tmp/test-home",
                "PATH": "/usr/bin",
                "ALPHA_PRIVATE_SENTINEL": "must-not-cross-boundary",
                "OPENAI_API_KEY": "must-not-cross-boundary",
            ]
        )

        let result = try await runner.run(task: sentinel, mode: .review, workingDirectory: workspace)
        let recordedInvocation = await process.recordedInvocation()
        let invocation = try XCTUnwrap(recordedInvocation)

        XCTAssertEqual(
            invocation.arguments.dropLast(),
            [
                "run", "--pure", "--model", "opencode/x-preview-f-free",
                "--variant", "max", "--agent", "codexswap-alpha-review", "--format", "json",
                "--file", invocation.arguments[invocation.arguments.count - 3], "--"
            ]
        )
        XCTAssertEqual(invocation.arguments.last, AlphaDelegationRunner.fixedPrompt)
        XCTAssertEqual(invocation.taskContents, sentinel)
        XCTAssertEqual(invocation.taskPermissions, 0o600)
        XCTAssertFalse(invocation.arguments.joined(separator: " ").contains(sentinel))
        XCTAssertFalse(invocation.environment.values.contains { $0.contains(sentinel) })
        XCTAssertNil(invocation.environment["ALPHA_PRIVATE_SENTINEL"])
        XCTAssertNil(invocation.environment["OPENAI_API_KEY"])
        XCTAssertTrue(
            Set(invocation.environment.keys).isSubset(of: [
                "HOME", "PATH", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE", "TERM",
                "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_CACHE_HOME",
                "OPENCODE_CONFIG_CONTENT",
            ])
        )
        XCTAssertNotEqual(invocation.environment["HOME"], "/tmp/test-home")
        XCTAssertEqual(invocation.homePermissions, 0o700)
        XCTAssertEqual(invocation.configPermissions, 0o700)
        XCTAssertEqual(
            invocation.directoryPermissions,
            [
                "HOME": 0o700,
                "TMPDIR": 0o700,
                "XDG_CONFIG_HOME": 0o700,
                "XDG_DATA_HOME": 0o700,
                "XDG_CACHE_HOME": 0o700,
            ]
        )
        XCTAssertNotEqual(invocation.currentDirectory.path, workspace.standardizedFileURL.path)
        XCTAssertEqual(
            invocation.currentDirectory.deletingLastPathComponent().standardizedFileURL.path,
            FileManager.default.temporaryDirectory.standardizedFileURL.path
        )
        XCTAssertTrue(invocation.currentDirectory.lastPathComponent.hasPrefix("codexswap-alpha-"))
        XCTAssertTrue(invocation.taskFile?.path.hasPrefix(invocation.currentDirectory.path + "/") == true)
        XCTAssertEqual(result.sessionID, "ses-123")
        XCTAssertEqual(result.text, "done")
        XCTAssertEqual(result.toolNames, ["read"])
        XCTAssertEqual(result.toolCount, 2)
        XCTAssertEqual(result.exitStatus, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: invocation.taskFile?.path ?? ""))
        XCTAssertFalse(FileManager.default.fileExists(atPath: invocation.homeDirectory?.path ?? ""))
        XCTAssertFalse(FileManager.default.fileExists(atPath: invocation.configDirectory?.path ?? ""))
    }

    func testReviewInjectsFailClosedPrimaryPermissionProfile() async throws {
        let workspace = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let output = #"{"type":"text","sessionID":"ses-perms","text":"ok"}"#

        let reviewProcess = process(stdout: output)
        _ = try await AlphaDelegationRunner(process: reviewProcess).run(
            task: "review",
            mode: .review,
            workingDirectory: workspace
        )
        let reviewRecordedInvocation = await reviewProcess.recordedInvocation()
        let reviewInvocation = try XCTUnwrap(reviewRecordedInvocation)
        let reviewConfig = try XCTUnwrap(reviewInvocation.environment["OPENCODE_CONFIG_CONTENT"])
        XCTAssertNotEqual(reviewConfig, "{}")
        let reviewRoot = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(reviewConfig.utf8)) as? [String: Any])
        let reviewAgent = try XCTUnwrap((reviewRoot["agent"] as? [String: Any])?["codexswap-alpha-review"] as? [String: Any])
        let reviewPermissions = try XCTUnwrap(reviewAgent["permission"] as? [String: Any])
        XCTAssertEqual(reviewAgent["mode"] as? String, "primary")
        XCTAssertEqual(reviewPermissions["*"] as? String, "deny")
        XCTAssertEqual(reviewPermissions["read"] as? String, "deny")
        XCTAssertEqual(reviewPermissions["glob"] as? String, "deny")
        XCTAssertEqual(reviewPermissions["grep"] as? String, "deny")
        XCTAssertEqual(reviewPermissions["list"] as? String, "deny")
        XCTAssertEqual(reviewPermissions["lsp"] as? String, "deny")
        XCTAssertEqual(reviewPermissions["webfetch"] as? String, "deny")
        XCTAssertEqual(reviewPermissions["websearch"] as? String, "deny")
        XCTAssertEqual(reviewPermissions["edit"] as? String, "deny")
        XCTAssertEqual(reviewPermissions["bash"] as? String, "deny")
        XCTAssertEqual(reviewPermissions["task"] as? String, "deny")
        XCTAssertEqual(reviewPermissions["external_directory"] as? String, "deny")

        XCTAssertEqual((reviewRoot["agent"] as? [String: Any])?.keys.sorted(), ["codexswap-alpha-review"])
    }

    func testWorkspaceSymlinkCannotReenableWorkspaceTools() async throws {
        let workspace = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let outside = try temporaryDirectory(named: "alpha-runner-symlink-outside")
        defer { try? FileManager.default.removeItem(at: outside) }

        let outsideFile = outside.appendingPathComponent("sentinel.txt")
        XCTAssertTrue(FileManager.default.createFile(atPath: outsideFile.path, contents: Data("secret".utf8)))
        let fileLink = workspace.appendingPathComponent("outside-link.txt")
        try FileManager.default.createSymbolicLink(at: fileLink, withDestinationURL: outsideFile)
        let directoryLink = workspace.appendingPathComponent("outside-directory", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: directoryLink, withDestinationURL: outside)

        let process = process(stdout: #"{"type":"text","text":"ok"}"#)
        _ = try await AlphaDelegationRunner(process: process).run(
            task: "symlink rules",
            mode: .review,
            workingDirectory: workspace
        )
        let recordedInvocation = await process.recordedInvocation()
        let invocation = try XCTUnwrap(recordedInvocation)
        let config = try XCTUnwrap(invocation.environment["OPENCODE_CONFIG_CONTENT"])
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(config.utf8)) as? [String: Any])
        let agent = try XCTUnwrap((root["agent"] as? [String: Any])?["codexswap-alpha-review"] as? [String: Any])
        let permissions = try XCTUnwrap(agent["permission"] as? [String: Any])
        // The exact symlink path is intentionally not interpolated into the
        // permission profile. OpenCode's matcher does not canonicalize a
        // symlink before applying path rules, so all workspace inspection
        // tools remain denied regardless of relative/absolute spelling.
        XCTAssertEqual(permissions["read"] as? String, "deny")
        XCTAssertEqual(permissions["glob"] as? String, "deny")
        XCTAssertEqual(permissions["list"] as? String, "deny")
        XCTAssertFalse(config.contains(fileLink.path))
        XCTAssertFalse(config.contains(directoryLink.path))
    }

    func testEditModeIsRejectedBeforeLaunchingOrCreatingAnAttachment() async throws {
        let workspace = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let process = process(stdout: #"{"type":"text","text":"must-not-run"}"#)

        await assertRunnerError(.unsupportedMode, operation: {
            _ = try await AlphaDelegationRunner(process: process).run(
                task: "edit",
                mode: .edit,
                workingDirectory: workspace
            )
        })
        let recordedInvocation = await process.recordedInvocation()
        XCTAssertNil(recordedInvocation)
    }

    func testExtractsFinalTextOnlyAndDeduplicatesBoundedToolNames() async throws {
        let workspace = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let output = #"""
{"type":"session.created","sessionID":"ses-extract"}
{"type":"message.part.updated","properties":{"sessionID":"ses-extract","part":{"id":"reasoning","type":"reasoning","text":"do not return"}}}
{"type":"message.part.delta","properties":{"sessionID":"ses-extract","messageID":"m","partID":"p","field":"text","delta":"duplicate delta"}}
{"type":"message.part.updated","properties":{"sessionID":"ses-extract","part":{"id":"p","type":"text","text":"Final "}}}
{"type":"message.part.updated","properties":{"sessionID":"ses-extract","part":{"id":"p","type":"text","text":"Final text"}}}
{"type":"tool_use","sessionID":"ses-extract","name":"read"}
{"type":"tool_use","sessionID":"ses-extract","name":"read"}
{"type":"tool_use","sessionID":"ses-extract","name":"grep"}
"""#
        let runner = AlphaDelegationRunner(
            process: process(stdout: output),
            timeout: .seconds(2)
        )

        let result = try await runner.run(task: "extract", mode: .review, workingDirectory: workspace)

        XCTAssertEqual(result.sessionID, "ses-extract")
        XCTAssertEqual(result.text, "Final text")
        XCTAssertEqual(result.toolNames, ["read", "grep"])
        XCTAssertEqual(result.toolCount, 3)
    }

    func testMalformedEventsAndMissingFinalTextFailClosed() async throws {
        let workspace = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }

        await assertRunnerError(.malformedEvent, operation: {
            let runner = AlphaDelegationRunner(process: process(stdout: "not-json"))
            _ = try await runner.run(task: "malformed", mode: .review, workingDirectory: workspace)
        })

        await assertRunnerError(.malformedEvent, operation: {
            let runner = AlphaDelegationRunner(process: process(stdout: #"{"sessionID":"missing-type"}"#))
            _ = try await runner.run(task: "missing-type", mode: .review, workingDirectory: workspace)
        })

        await assertRunnerError(.noText, operation: {
            let runner = AlphaDelegationRunner(process: process(stdout: #"{"type":"session.idle","sessionID":"ses-no-text"}"#))
            _ = try await runner.run(task: "no-text", mode: .review, workingDirectory: workspace)
        })
    }

    func testInputAndOutputBoundsAreEnforced() async throws {
        let workspace = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }

        await assertRunnerError(.emptyTask, operation: {
            let runner = AlphaDelegationRunner(process: process(stdout: #"{"type":"text","text":"ok"}"#))
            _ = try await runner.run(task: " \n\t", mode: .review, workingDirectory: workspace)
        })

        await assertRunnerError(.taskTooLarge, operation: {
            let runner = AlphaDelegationRunner(process: process(stdout: #"{"type":"text","text":"ok"}"#))
            _ = try await runner.run(task: String(repeating: "x", count: 32 * 1024 + 1), mode: .review, workingDirectory: workspace)
        })

        let outputProcess = process(stdout: #"{"type":"text","text":"ok"}"#)
        let runner = AlphaDelegationRunner(process: outputProcess, maxOutputBytes: 4)
        await assertRunnerError(.outputLimitExceeded, operation: {
            _ = try await runner.run(task: "bounded", mode: .review, workingDirectory: workspace)
        })

        let combinedOutputProcess = process(
            stdout: #"{"type":"text","text":"ok"}"#,
            stderr: "1234"
        )
        let combinedRunner = AlphaDelegationRunner(process: combinedOutputProcess, maxOutputBytes: 28)
        await assertRunnerError(.outputLimitExceeded, operation: {
            _ = try await combinedRunner.run(task: "combined-bounded", mode: .review, workingDirectory: workspace)
        })
    }

    func testMetadataIsSanitizedAndToolCountTracksCalls() async throws {
        let workspace = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let output = #"""
        {"type":"text","sessionID":"session with spaces","text":"ok"}
        {"type":"tool_use","name":"read"}
        {"type":"tool_use","name":"read"}
        {"type":"tool_use","name":"bad/name"}
        {"type":"tool_use","name":"grep"}
        {"type":"tool_use","name":""}
        """#
        let runner = AlphaDelegationRunner(process: process(stdout: output))

        let result = try await runner.run(task: "metadata", mode: .review, workingDirectory: workspace)

        XCTAssertEqual(result.sessionID, "redacted")
        XCTAssertEqual(result.toolNames, ["read", "redacted", "grep"])
        XCTAssertEqual(result.toolCount, 5)
    }

    func testTimeoutAndCancellationSurfaceWithoutLeakingProcessDetails() async throws {
        let workspace = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let timeoutProcess = RecordingProcess(output: .failure(AlphaDelegationRunnerError.timedOut))
        let timeoutRunner = AlphaDelegationRunner(process: timeoutProcess)
        await assertRunnerError(.timedOut, operation: {
            _ = try await timeoutRunner.run(task: "timeout", mode: .review, workingDirectory: workspace)
        })

        let cancellationProcess = RecordingProcess(
            output: .success(.init(stdout: Data(), exitStatus: 0)),
            holdUntilCancelled: true
        )
        let cancellationRunner = AlphaDelegationRunner(process: cancellationProcess)
        let task = Task {
            try await cancellationRunner.run(task: "cancel", mode: .review, workingDirectory: workspace)
        }
        while await cancellationProcess.recordedInvocation() == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
            // expected
        }
    }

    func testFoundationRunnerTerminatesDescendantsInOwnedProcessGroup() async throws {
        let workspace = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let script = workspace.appendingPathComponent("spawn-child.sh")
        let ready = workspace.appendingPathComponent("ready")
        let childInfoFile = workspace.appendingPathComponent("child.info")
        let scriptContents = #"""
        #!/bin/sh
        set -eu
        child_info_file="$1"
        ready="$2"
        printf ready > "$ready"
        /bin/sleep 30 &
        child="$!"
        shell_group="$(/bin/ps -o pgid= -p "$$" | /usr/bin/tr -d ' ')"
        child_group="$(/bin/ps -o pgid= -p "$child" | /usr/bin/tr -d ' ')"
        printf '%s:%s:%s:%s' "$$" "$shell_group" "$child" "$child_group" > "$child_info_file"
        wait "$child"
        """#
        XCTAssertTrue(FileManager.default.createFile(atPath: script.path, contents: Data(scriptContents.utf8)))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)

        let processRunner = FoundationAlphaDelegationProcessRunner()
        let runTask = Task<AlphaDelegationProcessOutput, Error> {
            try await processRunner.run(
                executable: script,
                arguments: [childInfoFile.path, ready.path],
                environment: ["PATH": "/usr/bin:/bin"],
                currentDirectory: workspace,
                timeout: .seconds(30),
                maxOutputBytes: 1024
            )
        }

        let readyDeadline = Date().addingTimeInterval(3)
        while !FileManager.default.fileExists(atPath: ready.path), Date() < readyDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: ready.path))
        let childDeadline = Date().addingTimeInterval(3)
        while !FileManager.default.fileExists(atPath: childInfoFile.path), Date() < childDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: childInfoFile.path))
        runTask.cancel()
        do {
            _ = try await runTask.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
            // expected
        }

        let childInfo = (try? String(contentsOf: childInfoFile, encoding: .utf8)) ?? ""
        let identities = childInfo.split(separator: ":").compactMap { Int32($0) }
        XCTAssertEqual(identities.count, 4)
        let shellPID = try XCTUnwrap(identities.first)
        let shellGroupID = try XCTUnwrap(identities.dropFirst().first)
        let childPID = try XCTUnwrap(identities.dropFirst(2).first)
        let childGroupID = try XCTUnwrap(identities.dropFirst(3).first)
        XCTAssertEqual(shellPID, shellGroupID, "runner must own a group named after the launched PID")
        XCTAssertEqual(childGroupID, shellGroupID, "descendant must inherit the owned process group")
        let exitDeadline = Date().addingTimeInterval(2)
        while kill(childPID, 0) == 0, Date() < exitDeadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertNotEqual(kill(childPID, 0), 0, "descendant survived group teardown")
    }

    func testFoundationRunnerReconcilesDetachedChildAfterLeaderExitsSuccessfully() async throws {
        let workspace = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let script = workspace.appendingPathComponent("detached-success.sh")
        let childInfoFile = workspace.appendingPathComponent("detached-child.pid")
        let scriptContents = #"""
        #!/bin/sh
        set -eu
        child_info_file="$1"
        /bin/sleep 30 >/dev/null 2>/dev/null &
        child="$!"
        printf '%s' "$child" > "$child_info_file"
        exit 0
        """#
        XCTAssertTrue(FileManager.default.createFile(atPath: script.path, contents: Data(scriptContents.utf8)))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)

        let result = try await runFoundationScript(
            script: script,
            arguments: [childInfoFile.path],
            workspace: workspace,
            timeout: .seconds(3)
        )
        XCTAssertEqual(result.exitStatus, 0)
        let childPID = try await waitForPID(in: childInfoFile)
        let childExited = await waitForProcessExit(childPID)
        XCTAssertTrue(childExited, "detached child survived successful leader reconciliation")
    }

    func testFoundationRunnerReconcilesPipeRetainingChildAfterLeaderExitsSuccessfully() async throws {
        let workspace = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let script = workspace.appendingPathComponent("pipe-retaining-success.sh")
        let childInfoFile = workspace.appendingPathComponent("pipe-child.pid")
        let scriptContents = #"""
        #!/bin/sh
        set -eu
        child_info_file="$1"
        /bin/sleep 30 &
        child="$!"
        printf '%s' "$child" > "$child_info_file"
        exit 0
        """#
        XCTAssertTrue(FileManager.default.createFile(atPath: script.path, contents: Data(scriptContents.utf8)))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)

        let started = Date()
        let result = try await runFoundationScript(
            script: script,
            arguments: [childInfoFile.path],
            workspace: workspace,
            timeout: .seconds(3)
        )
        XCTAssertEqual(result.exitStatus, 0)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2.0, "pipe-retaining child delayed runner return")
        let childPID = try await waitForPID(in: childInfoFile)
        let childExited = await waitForProcessExit(childPID)
        XCTAssertTrue(childExited, "pipe-retaining child survived successful reconciliation")
    }

    func testFoundationRunnerTimeoutReconcilesLeaderAndDescendantPromptly() async throws {
        let workspace = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let script = workspace.appendingPathComponent("timeout-group.sh")
        let infoFile = workspace.appendingPathComponent("timeout-group.info")
        let scriptContents = #"""
        #!/bin/sh
        set -eu
        info_file="$1"
        /bin/sleep 30 &
        child="$!"
        printf '%s:%s' "$$" "$child" > "$info_file"
        wait "$child"
        """#
        XCTAssertTrue(FileManager.default.createFile(atPath: script.path, contents: Data(scriptContents.utf8)))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)

        let started = Date()
        do {
            _ = try await runFoundationScript(
                script: script,
                arguments: [infoFile.path],
                workspace: workspace,
                timeout: .milliseconds(250)
            )
            XCTFail("expected timeout")
        } catch let error as AlphaDelegationRunnerError {
            XCTAssertEqual(error, .timedOut)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5, "timeout teardown was not prompt")
        let identities = (try await waitForText(in: infoFile))
            .split(separator: ":")
            .compactMap { Int32($0) }
        XCTAssertEqual(identities.count, 2)
        let leaderPID = try XCTUnwrap(identities.first)
        let childPID = try XCTUnwrap(identities.dropFirst().first)
        let leaderExited = await waitForProcessExit(leaderPID)
        let childExited = await waitForProcessExit(childPID)
        XCTAssertTrue(leaderExited)
        XCTAssertTrue(childExited)
    }

    func testFoundationRunnerImmediateForkStressKeepsChildrenInOwnedGroupAndCleansThem() async throws {
        let workspace = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let script = workspace.appendingPathComponent("immediate-fork-stress.sh")
        let childInfoFile = workspace.appendingPathComponent("stress-child.info")
        let scriptContents = #"""
        #!/bin/sh
        set -eu
        child_info_file="$1"
        child_group_file="$2"
        /bin/sleep 30 &
        child="$!"
        shell_group="$(/bin/ps -o pgid= -p "$$" | /usr/bin/tr -d ' ')"
        child_group="$(/bin/ps -o pgid= -p "$child" | /usr/bin/tr -d ' ')"
        printf '%s:%s:%s' "$$" "$shell_group" "$child_group" > "$child_info_file"
        printf '%s' "$child" > "$child_group_file"
        exit 0
        """#
        XCTAssertTrue(FileManager.default.createFile(atPath: script.path, contents: Data(scriptContents.utf8)))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)

        for _ in 0..<12 {
            try? FileManager.default.removeItem(at: childInfoFile)
            let childPIDFile = workspace.appendingPathComponent("stress-child.pid")
            try? FileManager.default.removeItem(at: childPIDFile)
            let result = try await runFoundationScript(
                script: script,
                arguments: [childInfoFile.path, childPIDFile.path],
                workspace: workspace,
                timeout: .seconds(3)
            )
            XCTAssertEqual(result.exitStatus, 0)
            let info = try await waitForText(in: childInfoFile)
            let identities = info.split(separator: ":").compactMap { Int32($0) }
            XCTAssertEqual(identities.count, 3)
            let shellPID = try XCTUnwrap(identities.first)
            let shellGroupID = try XCTUnwrap(identities.dropFirst().first)
            let childGroupID = try XCTUnwrap(identities.dropFirst(2).first)
            XCTAssertEqual(shellPID, shellGroupID)
            XCTAssertEqual(childGroupID, shellGroupID)
            let childPID = try await waitForPID(in: childPIDFile)
            let childExited = await waitForProcessExit(childPID)
            XCTAssertTrue(childExited, "immediate child survived owned-group teardown")
        }
    }

    private func runFoundationScript(
        script: URL,
        arguments: [String],
        workspace: URL,
        timeout: Duration
    ) async throws -> AlphaDelegationProcessOutput {
        let runner = FoundationAlphaDelegationProcessRunner()
        let completion = ProcessRunCompletionProbe()
        let task = Task {
            do {
                let output = try await runner.run(
                    executable: script,
                    arguments: arguments,
                    environment: ["PATH": "/usr/bin:/bin"],
                    currentDirectory: workspace,
                    timeout: timeout,
                    maxOutputBytes: 1024
                )
                await completion.complete(.success(output))
            } catch {
                await completion.complete(.failure(error))
            }
        }
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if let result = await completion.result {
                _ = await task.result
                return try result.get()
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        task.cancel()
        _ = await task.result
        XCTFail("Foundation process runner did not reconcile its process group before the deadline")
        throw AlphaDelegationRunnerError.timedOut
    }

    private func waitForText(in file: URL) async throws -> String {
        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline {
            if let text = try? String(contentsOf: file, encoding: .utf8), !text.isEmpty {
                return text
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw AlphaDelegationRunnerError.timedOut
    }

    private func waitForPID(in file: URL) async throws -> Int32 {
        let text = try await waitForText(in: file)
        guard let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0 else {
            throw AlphaDelegationRunnerError.malformedEvent
        }
        return pid
    }

    private func waitForProcessExit(_ pid: Int32) async -> Bool {
        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline {
            if kill(pid, 0) != 0 { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return kill(pid, 0) != 0
    }

    func testWorkingDirectoryRejectsNonDirectoriesSymlinksAndFilesystemRoot() async throws {
        let workspace = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let file = workspace.appendingPathComponent("file.txt")
        XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: Data("x".utf8)))
        let link = workspace.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: workspace)

        await assertRunnerError(.workingDirectoryNotDirectory, operation: {
            let runner = AlphaDelegationRunner(process: process(stdout: #"{"type":"text","text":"ok"}"#))
            _ = try await runner.run(task: "file", mode: .review, workingDirectory: file)
        })

        await assertRunnerError(.workingDirectorySymlink, operation: {
            let runner = AlphaDelegationRunner(process: process(stdout: #"{"type":"text","text":"ok"}"#))
            _ = try await runner.run(task: "link", mode: .review, workingDirectory: link)
        })

        let unsafeDirectories = [
            URL(fileURLWithPath: "/", isDirectory: true),
            URL(fileURLWithPath: "/Users", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser,
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Projects", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gnupg", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".aws", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".opencode", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/opencode", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Keychains", isDirectory: true),
            URL(fileURLWithPath: "/System", isDirectory: true),
            URL(fileURLWithPath: "/private", isDirectory: true),
            URL(fileURLWithPath: "/var", isDirectory: true),
            URL(fileURLWithPath: "/Volumes", isDirectory: true),
        ]
        for directory in unsafeDirectories {
            await assertRunnerError(.unsafeWorkingDirectory, operation: {
                let runner = AlphaDelegationRunner(process: process(stdout: #"{"type":"text","text":"ok"}"#))
                _ = try await runner.run(task: "root", mode: .review, workingDirectory: directory)
            })
        }
    }

    func testWorkingDirectoryAllowsOrdinaryProjectAndTemporaryDescendants() async throws {
        let workspace = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let candidates = [
            workspace,
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Projects/CodexSwap", isDirectory: true),
        ].filter { directory in
            FileManager.default.fileExists(atPath: directory.path)
        }

        for directory in candidates {
            let runner = AlphaDelegationRunner(process: process(stdout: #"{"type":"text","text":"ok"}"#))
            let result = try await runner.run(task: "descendant", mode: .review, workingDirectory: directory)
            XCTAssertEqual(result.text, "ok")
        }
    }

    func testWorkingDirectoryRejectsNestedSymlinkEscape() async throws {
        let workspace = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let outside = try temporaryDirectory(named: "alpha-runner-outside")
        defer { try? FileManager.default.removeItem(at: outside) }
        let escapedChild = outside.appendingPathComponent("child", isDirectory: true)
        try FileManager.default.createDirectory(at: escapedChild, withIntermediateDirectories: false)
        let link = workspace.appendingPathComponent("nested-link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let escapedPath = link.appendingPathComponent("child", isDirectory: true)

        await assertRunnerError(.workingDirectorySymlink, operation: {
            let runner = AlphaDelegationRunner(process: process(stdout: #"{"type":"text","text":"must-not-run"}"#))
            _ = try await runner.run(task: "nested-symlink", mode: .review, workingDirectory: escapedPath)
        })
    }

    func testNonZeroExitIsReturnedAsTypedFailure() async throws {
        let workspace = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        await assertRunnerError(.nonZeroExit(17), operation: {
            let runner = AlphaDelegationRunner(process: process(
                stdout: #"{"type":"text","text":"ignored"}"#,
                exitStatus: 17
            ))
            _ = try await runner.run(task: "failed", mode: .review, workingDirectory: workspace)
        })
    }
}
