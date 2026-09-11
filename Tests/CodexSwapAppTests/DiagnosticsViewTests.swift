import XCTest
import Foundation
@testable import CodexSwapApp

@MainActor
final class DiagnosticsViewTests: XCTestCase {
    func testDiagnosticsPaneIsDiscoverableInSettings() {
        XCTAssertTrue(SettingsPane.allCases.contains(.diagnostics))
        XCTAssertEqual(SettingsPane.diagnostics.title, "Diagnostics")
        XCTAssertEqual(SettingsPane.diagnostics.symbol, "waveform.path.ecg")
    }

    func testDiagnosticsExportCreatesOwnerOnlyFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexswap-diagnostics-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let destination = directory.appendingPathComponent("diagnostics.json")
        try DiagnosticsExportWriter.write(data: Data("{}".utf8), to: destination)

        let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(permissions, 0o600)
        XCTAssertEqual(try Data(contentsOf: destination), Data("{}".utf8))

        try Data("old".utf8).write(to: destination)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o644)],
            ofItemAtPath: destination.path
        )
        try DiagnosticsExportWriter.write(data: Data("new".utf8), to: destination)
        let replacedAttributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        let replacedPermissions = (replacedAttributes[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(replacedPermissions, 0o600)
        XCTAssertEqual(try Data(contentsOf: destination), Data("new".utf8))
    }
}
