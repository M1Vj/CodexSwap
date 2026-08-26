import XCTest
@testable import CodexSwapApp
import SwapKit

final class AlphaDelegationMCPUIStateTests: XCTestCase {
    func testStaleRefreshCannotOverwriteNewerStatus() {
        var state = AlphaDelegationMCPPresentationState()

        let first = state.beginRefresh()
        let second = state.beginRefresh()

        XCTAssertFalse(state.apply(status: .installed, generation: first))
        XCTAssertEqual(state.phase, .loading)
        XCTAssertTrue(state.apply(status: .notInstalled, generation: second))
        XCTAssertEqual(state.phase, .notInstalled)
    }

    func testConflictIsSurfacedAndDoesNotBecomeActionable() {
        var state = AlphaDelegationMCPPresentationState()

        let generation = state.beginRefresh()
        XCTAssertTrue(state.apply(status: .conflict(message: "owned elsewhere"), generation: generation))
        XCTAssertEqual(state.phase, .conflict(message: "owned elsewhere"))
        XCTAssertFalse(state.isBusy)
    }

    @MainActor
    func testReviewOnlyCopyNamesTrustBoundaryAndNoRemovalAction() {
        let copy = AlphaDelegationMCPSection.copy

        XCTAssertTrue(copy.contains("GPT-5.6 Sol"))
        XCTAssertTrue(copy.contains("file contents the invoking client includes in that task"))
        XCTAssertTrue(copy.contains("Alpha cannot inspect the live workspace"))
        XCTAssertTrue(copy.contains("When Codex or another configured MCP client invokes the review tool"))
        XCTAssertTrue(copy.contains("server cannot enforce a separate human confirmation"))
        XCTAssertTrue(copy.contains("In the intended Codex workflow, GPT-5.6 Sol remains the parent/orchestrator, and Alpha output returns to Sol as untrusted evidence"))
        XCTAssertTrue(copy.contains("Another configured MCP client may invoke the tool without Sol as its parent"))
        XCTAssertTrue(copy.contains("global MCP registration may affect future or new Codex sessions"))
        XCTAssertTrue(copy.contains("reserved codexswap_alpha name is unused"))
        XCTAssertTrue(copy.contains("not a native Codex child"))
        XCTAssertFalse(copy.contains("uninstall"))
        XCTAssertFalse(copy.contains("edit files"))
    }
}
