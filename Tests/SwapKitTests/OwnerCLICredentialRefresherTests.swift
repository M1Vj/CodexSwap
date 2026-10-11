import Darwin
import Foundation
import XCTest
@testable import SwapKit

final class OwnerCLICredentialRefresherTests: XCTestCase {
    private var roots: [URL] = []

    override func tearDown() {
        for root in roots {
            let home = root.appendingPathComponent("empty-home")
            if let groupText = try? String(contentsOf: home.appendingPathComponent("pgid"), encoding: .utf8),
               let leaderText = try? String(contentsOf: home.appendingPathComponent("pid"), encoding: .utf8),
               let group = Int32(groupText), group > 0, groupText == leaderText {
                _ = Darwin.killpg(group, SIGKILL)
            }
            try? FileManager.default.removeItem(at: root)
        }
        roots.removeAll()
        super.tearDown()
    }

    func testClientSendsInitializeInitializedAndRefreshAccountReadInOrder() async throws {
        let fixture = try makeServer(mode: "success")
        let binary = fixture.binary.path
        let refresher = OwnerCLICredentialRefresher(binary: { binary }, timeout: 2)

        let refreshed = await refresher.refresh(home: fixture.home)

        XCTAssertTrue(refreshed)
        let record = try await record(fixture.home)
        XCTAssertEqual(record["home"] as? String, fixture.home.path)
        XCTAssertEqual(record["args"] as? [String], ["app-server"])
        let path = try XCTUnwrap(record["path"] as? String)
        XCTAssertTrue(path.split(separator: ":").contains(Substring(fixture.binary.deletingLastPathComponent().path)))
        let messages = try XCTUnwrap(record["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.compactMap { $0["method"] as? String }, ["initialize", "initialized", "account/read"])
        let params = try XCTUnwrap(messages[0]["params"] as? [String: Any])
        let clientInfo = try XCTUnwrap(params["clientInfo"] as? [String: Any])
        XCTAssertEqual(clientInfo["name"] as? String, "codexswap")
        XCTAssertFalse((clientInfo["version"] as? String ?? "").isEmpty)
        let readParams = try XCTUnwrap(messages[2]["params"] as? [String: Any])
        XCTAssertEqual(readParams["refreshToken"] as? Bool, true)
        try await waitForMarker("exited", home: fixture.home)
    }

    func testClientTimeoutKillsServerThatNeverAnswersAndIgnoresTerminate() async throws {
        let fixture = try makeServer(mode: "hang")
        let binary = fixture.binary.path
        let refresher = OwnerCLICredentialRefresher(binary: { binary }, timeout: 0.5)
        let start = Date()

        let refreshed = await refresher.refresh(home: fixture.home)

        XCTAssertFalse(refreshed)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        try await waitForMarker("pid", home: fixture.home)
        let pidText = try String(contentsOf: fixture.home.appendingPathComponent("pid"), encoding: .utf8)
        let pid = try XCTUnwrap(Int32(pidText))
        try await assertProcessGone(pid)
    }

    func testClientRejectsNonzeroExitRPCErrorAndExcessiveOutput() async throws {
        for mode in ["nonzero", "error", "overflow", "signed-out"] {
            let fixture = try makeServer(mode: mode)
            let binary = fixture.binary.path
            let result = await OwnerCLICredentialRefresher(binary: { binary }, timeout: 2).refresh(home: fixture.home)
            XCTAssertFalse(result, mode)
        }
    }

    func testClientCancellationPreservesStartedRefreshUntilCompletion() async throws {
        try await assertCancellationPreservesStartedRefresh(processTree: false)
    }

    func testNonExecLauncherCleansWholeGroupOnSuccessFailureAndTimeout() async throws {
        for mode in ["success", "error", "hang"] {
            let fixture = try makeServer(mode: mode, processTree: true)
            let binary = fixture.binary.path
            let result = await OwnerCLICredentialRefresher(binary: { binary }, timeout: mode == "hang" ? 0.5 : 2).refresh(home: fixture.home)
            XCTAssertEqual(result, mode == "success", mode)
            if mode == "success" { try await waitForMarker("launcher-exited", home: fixture.home) }
            try await assertGroupGone(home: fixture.home)
        }
    }

    func testNonExecLauncherCancellationPreservesRefreshThenCleansWholeGroup() async throws {
        try await assertCancellationPreservesStartedRefresh(processTree: true)
    }

    private func assertCancellationPreservesStartedRefresh(processTree: Bool) async throws {
        let fixture = try makeServer(mode: "gated", processTree: processTree)
        let binary = fixture.binary.path
        let task = Task { await OwnerCLICredentialRefresher(binary: { binary }, timeout: 2).refresh(home: fixture.home) }
        try await waitForMarker("refresh-started", home: fixture.home)
        task.cancel()
        try await Task.sleep(for: .milliseconds(100))
        let pid = try XCTUnwrap(Int32(try String(contentsOf: fixture.home.appendingPathComponent("pid"), encoding: .utf8)))
        XCTAssertEqual(Darwin.kill(pid, 0), 0, "the CLI must remain alive until the gated refresh completes")
        try Data("release".utf8).write(to: fixture.home.appendingPathComponent("release-refresh"))
        let result = await task.value
        XCTAssertTrue(result)
        try await waitForMarker("refresh-completed", home: fixture.home)
        if processTree { try await assertGroupGone(home: fixture.home) }
        else { try await assertProcessGone(pid) }
    }

    private func waitForMarker(_ name: String, home: URL) async throws {
        let path = home.appendingPathComponent(name).path
        let deadline = Date().addingTimeInterval(2)
        while !FileManager.default.fileExists(atPath: path), Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: path), "missing fixture marker: \(name)")
    }

    private func assertProcessGone(_ pid: Int32) async throws {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if Darwin.kill(pid, 0) == -1, errno == ESRCH { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        let result = Darwin.kill(pid, 0)
        let error = errno
        XCTAssertEqual(result, -1)
        XCTAssertEqual(error, ESRCH)
    }

    private func assertGroupGone(home: URL) async throws {
        try await waitForMarker("pgid", home: home)
        try await waitForMarker("child-ready", home: home)
        let pgid = try XCTUnwrap(Int32(try String(contentsOf: home.appendingPathComponent("pgid"), encoding: .utf8)))
        try await waitForMarker("pid", home: home)
        let pid = try XCTUnwrap(Int32(try String(contentsOf: home.appendingPathComponent("pid"), encoding: .utf8)))
        XCTAssertEqual(pgid, pid, "launcher must lead its own process group")
        try await assertProcessGone(-pgid)
    }

    private func record(_ home: URL) async throws -> [String: Any] {
        try await waitForMarker("protocol.json", home: home)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: home.appendingPathComponent("protocol.json"))) as? [String: Any])
    }

    private func makeServer(mode: String, processTree: Bool = false) throws -> (home: URL, binary: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("owner-cli-test-\(UUID().uuidString)")
        roots.append(root)
        let home = root.appendingPathComponent("empty-home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let binary = root.appendingPathComponent("fake-codex")
        var script = #"""
        #!/bin/sh
        printf '%s' "$$" > "$CODEX_HOME/pid"
        exec /usr/bin/python3 -c '
        import json, os, signal, sys, time
        mode = "MODE"
        home = os.environ["CODEX_HOME"]
        if TREE:
            with open(os.path.join(home, "pgid"), "w") as f:
                f.write(str(os.getpgrp()))
            child = os.fork()
            if child == 0:
                signal.signal(signal.SIGTERM, signal.SIG_IGN)
                os.close(0)
                with open(os.path.join(home, "child-ready"), "w") as f:
                    f.write("ready")
                while True:
                    time.sleep(1)
            while not os.path.exists(os.path.join(home, "child-ready")):
                time.sleep(0.001)
        if mode == "hang":
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
        messages = []
        def emit(message):
            print(json.dumps(message), flush=True)
        first = json.loads(sys.stdin.readline())
        messages.append(first)
        if mode == "hang":
            while True:
                time.sleep(1)
        if mode == "overflow":
            print("x" * 1048577, flush=True)
            sys.exit(0)
        emit({"id": first["id"], "result": {"userAgent": "fixture"}})
        messages.append(json.loads(sys.stdin.readline()))
        read = json.loads(sys.stdin.readline())
        messages.append(read)
        with open(os.path.join(home, "protocol.json"), "w") as f:
            json.dump({"home": home, "path": os.environ["PATH"], "args": sys.argv[1:], "messages": messages}, f)
        if mode == "gated":
            with open(os.path.join(home, "refresh-started"), "w") as f:
                f.write("started")
            while not os.path.exists(os.path.join(home, "release-refresh")):
                time.sleep(0.001)
            with open(os.path.join(home, "refresh-completed"), "w") as f:
                f.write("completed")
        emit({"method": "account/updated", "params": {}})
        if mode == "error":
            emit({"id": read["id"], "error": {"code": -32603, "message": "fixture failure"}})
        elif mode == "signed-out":
            emit({"id": read["id"], "result": {"account": None, "requiresOpenaiAuth": True}})
        else:
            emit({"id": read["id"], "result": {"account": {"type": "chatgpt", "email": None, "planType": "plus"}, "requiresOpenaiAuth": True}})
        if mode == "nonzero":
            sys.exit(7)
        for line in sys.stdin:
            pass
        with open(os.path.join(home, "exited"), "w") as f:
            f.write("clean")
        ' "$@"
        """#.replacingOccurrences(of: "MODE", with: mode)
            .replacingOccurrences(of: "TREE", with: processTree ? "True" : "False")
        if processTree {
            script = script.replacingOccurrences(of: "exec /usr/bin/python3", with: "/usr/bin/python3")
                .replacingOccurrences(of: "' \"$@\"", with: "' \"$@\" <&0 &\nwait \"$!\"\nprintf exited > \"$CODEX_HOME/launcher-exited\"")
        }
        try Data(script.utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        return (home, binary)
    }
}
