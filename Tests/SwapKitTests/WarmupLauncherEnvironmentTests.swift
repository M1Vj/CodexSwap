import Foundation
import XCTest
@testable import SwapKit

final class WarmupLauncherEnvironmentTests: XCTestCase {
    func testMinimalGUIPathIncludesInterpreterLocationsWithoutRelativeEntries() {
        let path = ProcessWarmupRunner.executableSearchPath(
            binary: "/opt/homebrew/bin/codex",
            inheritedPath: "/usr/bin:/bin::.:relative:/custom/bin:/usr/bin"
        ).split(separator: ":").map(String.init)

        XCTAssertEqual(path.first, "/opt/homebrew/bin")
        XCTAssertTrue(path.contains("/usr/local/bin"))
        XCTAssertTrue(path.contains("/custom/bin"))
        XCTAssertTrue(path.contains("/usr/sbin"))
        XCTAssertTrue(path.contains("/sbin"))
        XCTAssertTrue(path.allSatisfy { $0.hasPrefix("/") })
        XCTAssertEqual(path.count, Set(path).count)
    }

    func testMissingGUIPathStillSupportsHomebrewNode() {
        let path = ProcessWarmupRunner.executableSearchPath(
            binary: "/Applications/ChatGPT.app/Contents/Resources/codex",
            inheritedPath: nil
        )

        XCTAssertTrue(path.contains("/opt/homebrew/bin"))
        XCTAssertTrue(path.contains("/usr/local/bin"))
        XCTAssertTrue(path.contains("/usr/bin"))
    }

    func testWarmupFindsInterpreterBesideSelectedLauncher() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("warmup-launcher-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let interpreterName = "warmup-interpreter-\(UUID().uuidString)"
        let interpreter = root.appendingPathComponent(interpreterName)
        let launcher = root.appendingPathComponent("codex")
        try "#!/bin/sh\nexit 0\n".write(to: interpreter, atomically: true, encoding: .utf8)
        try "#!/usr/bin/env \(interpreterName)\n".write(to: launcher, atomically: true, encoding: .utf8)
        for executable in [interpreter, launcher] {
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        }

        try await ProcessWarmupRunner(binary: launcher.path, timeoutSeconds: 5)
            .run(alias: "synthetic", proxyURL: URL(string: "http://127.0.0.1:58432")!)
    }
}
