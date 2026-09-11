import Foundation
import XCTest
@testable import SwapKit

private struct CancelledRecoveryUsage: UsageFetching {
    func fetch(accessToken: String, accountID: String) async throws -> [UsageWindow] {
        throw CancellationError()
    }
}

final class AuthenticationRecoveryDiagnosticsTests: XCTestCase {
    func testRecoveryDiagnosticsUseCorrelationAndKeepCancellationOutOfNetwork() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("auth-recovery-diagnostics-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let diagnostics = DiagnosticsLog(url: root.appendingPathComponent("diagnostics-v1.jsonl"))
        let store = AccountStore(url: root.appendingPathComponent("accounts.json"))
        let usage = CancelledRecoveryUsage()

        let rejected = await AuthenticationRecovery.recover(
            alias: "missing",
            candidate: Account(alias: "synthetic"),
            store: store,
            usage: usage,
            diagnosticsLog: diagnostics
        )

        let accountID = "synthetic-account"
        let expiry = Int(Date().addingTimeInterval(3_600).timeIntervalSince1970)
        let payload = try JSONSerialization.data(withJSONObject: ["account_id": accountID, "exp": expiry])
        let encodedPayload = payload
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let accessToken = "e30.\(encodedPayload).sig"
        let candidate = Account(
            alias: "synthetic",
            accountID: accountID,
            accessToken: accessToken,
            refreshToken: "synthetic-refresh",
            idToken: "synthetic-id",
            needsLogin: true,
            credentialSource: AccountCredentialSource(kind: .nativeAuth, path: "/tmp/synthetic-auth.json")
        )
        await store.upsert(candidate)

        let cancelled = await AuthenticationRecovery.recover(
            alias: candidate.alias,
            candidate: candidate,
            store: store,
            usage: usage,
            diagnosticsLog: diagnostics
        )

        XCTAssertEqual(rejected, .candidateRejected)
        XCTAssertEqual(cancelled, .usageFailed)
        let records = diagnostics.snapshot().records
        XCTAssertEqual(records.count, 4)
        XCTAssertTrue(records.allSatisfy { $0.component == .accounts && $0.operation == .authentication })
        XCTAssertEqual(Set(records.compactMap { $0.correlationID }).count, 2)
        XCTAssertEqual(records.filter { $0.outcome == .started }.count, 2)
        XCTAssertEqual(records.filter { $0.outcome == .failed && $0.code == .invalidInput }.count, 1)
        XCTAssertEqual(records.filter { $0.outcome == .cancelled && $0.code == .none }.count, 1)
        XCTAssertEqual(records.filter { $0.outcome == .failed && $0.code == .network }.count, 0)
    }
}
