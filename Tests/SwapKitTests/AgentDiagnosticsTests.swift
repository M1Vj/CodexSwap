import Foundation
import XCTest
@testable import SwapKit

final class AgentDiagnosticsTests: XCTestCase {
    func testRoutingMirrorsTypedFailureAndCorrelationIntoDiagnostics() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("diagnostics-routing-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let diagnostics = DiagnosticsLog(url: root.appendingPathComponent("diagnostics-v1.jsonl"))
        let routing = RoutingDecisionLog(url: root.appendingPathComponent("routing.jsonl"), diagnosticsLog: diagnostics)
        let correlationID = UUID()
        await routing.write(RoutingDecisionLogRecord(event: .authFailure, rootRequestID: correlationID, status: 401, reason: .tokenRevoked))
        let record = try XCTUnwrap(diagnostics.snapshot().records.first)
        XCTAssertEqual(record.component, .routing)
        XCTAssertEqual(record.operation, .authentication)
        XCTAssertEqual(record.outcome, .failed)
        XCTAssertEqual(record.code, .revoked)
        XCTAssertEqual(record.correlationID, correlationID)
        XCTAssertEqual(record.status, 401)
    }

    func testDiagnosticsParserRejectsMutationFlagsAndExtraArguments() throws {
        XCTAssertEqual(try AgentCLIParser.parse(["agent", "diagnostics", "--json"]).operation, .diagnostics)
        XCTAssertThrowsError(try AgentCLIParser.parse(["agent", "diagnostics", "--confirm"]))
        XCTAssertThrowsError(try AgentCLIParser.parse(["agent", "diagnostics", "--dry-run"]))
        XCTAssertThrowsError(try AgentCLIParser.parse(["agent", "diagnostics", "unexpected"]))
    }

    func testDiagnosticsReadsOnlyItsStructuredLogWithoutLiveProxy() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("diagnostics-cli-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let log = DiagnosticsLog(url: root.appendingPathComponent("diagnostics-v1.jsonl"))
        log.record(component: .storage, operation: .persistence, outcome: .failed, level: .error, code: .io)
        try Data("private-unrelated-content".utf8).write(to: root.appendingPathComponent("automation.log"))
        let cli = AgentCLI(
            store: AccountStore(url: root.appendingPathComponent("accounts.json")),
            settingsStore: SettingsStore(url: root.appendingPathComponent("settings.json")),
            supportDir: root,
            runtimeURLProvider: { nil }
        )
        let result = await cli.run(["agent", "diagnostics", "--json"])
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.envelope.ok)
        let encoded = try JSONEncoder().encode(result.envelope)
        let text = String(decoding: encoded, as: UTF8.self)
        XCTAssertTrue(text.contains("persistence"))
        XCTAssertFalse(text.contains("private-unrelated-content"))
    }
}
