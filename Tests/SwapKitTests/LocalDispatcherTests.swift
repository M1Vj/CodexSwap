import XCTest
@testable import SwapKit

final class LocalDispatcherTests: XCTestCase {
    func testIsDispatcherBaseURL() {
        XCTAssertTrue(LocalDispatcher.isDispatcherBaseURL("http://127.0.0.1:58444/zen/v1"))
        XCTAssertTrue(LocalDispatcher.isDispatcherBaseURL("http://localhost:58444/zen/v1"))
        XCTAssertTrue(LocalDispatcher.isDispatcherBaseURL("http://[::1]:58444/zen/v1"))
        XCTAssertFalse(LocalDispatcher.isDispatcherBaseURL("https://opencode.ai/zen/v1"))
        XCTAssertFalse(LocalDispatcher.isDispatcherBaseURL("http://127.0.0.1:8080/zen/v1"))
        XCTAssertFalse(LocalDispatcher.isDispatcherBaseURL("http://127.0.0.1:58444.evil.com/zen/v1"))
        XCTAssertFalse(LocalDispatcher.isDispatcherBaseURL("not a url"))
    }

    func testResponsesURL() {
        XCTAssertEqual(
            LocalDispatcher.responsesURL(forBaseURL: "http://127.0.0.1:58444/zen/v1")?.absoluteString,
            "http://127.0.0.1:58444/codex/responses"
        )
        XCTAssertEqual(
            LocalDispatcher.responsesURL(forBaseURL: "http://localhost:58444")?.absoluteString,
            "http://localhost:58444/codex/responses"
        )
        XCTAssertNil(LocalDispatcher.responsesURL(forBaseURL: "https://opencode.ai/zen/v1"))
    }

    func testIdentityHeaders() {
        let headers = LocalDispatcher.identityHeaders()
        let session = headers["x-opencode-session"]
        XCTAssertNotNil(session)
        XCTAssertTrue(session!.matches(of: /^ses_[A-Za-z0-9]{26}$/).count > 0)
        XCTAssertEqual(LocalDispatcher.sessionID(), LocalDispatcher.sessionID(), "stable session id")
        XCTAssertEqual(headers["x-opencode-client"], "codexswap")
        XCTAssertTrue(headers["x-opencode-request"]!.hasPrefix("req_"))
    }

    func testRegistryRefreshCachesSnapshot() async {
        let fetcher = MockFetcher(venue: .success([
            BridgedModel(modelID: "muse-spark-1.3-contributor-free", baseURL: LocalDispatcher.zenBase)
        ]))
        let registry = LocalDispatcherRegistry(fetcher: fetcher.fetch)
        let models = await registry.refreshIfStale()
        XCTAssertEqual(models.map(\.modelID), ["muse-spark-1.3-contributor-free"])
        XCTAssertEqual(registry.snapshot().map(\.modelID), ["muse-spark-1.3-contributor-free"])
        // Only one underlying fetch despite two calls within maxAge.
        XCTAssertEqual(fetcher.calls, 1)
        let again = await registry.refreshIfStale()
        XCTAssertEqual(fetcher.calls, 1)
        XCTAssertEqual(again.count, 1)
    }

    func testRegistryKeepsStaleOnFailure() async {
        let fetcher = MockFetcher(venue: .failure(URLError(.notConnectedToInternet)))
        let registry = LocalDispatcherRegistry(fetcher: fetcher.fetch)
        let models = await registry.refreshIfStale(maxAge: 0)
        XCTAssertEqual(models, [])
        XCTAssertEqual(registry.snapshot(), [])
    }

    func testParseIncludesDispatcherModelsInCatalog() throws {
        let raw = """
        {"models":[{"slug":"gpt-5.6-sol","display_name":"S","supported_reasoning_levels":[{"effort":"high"}]}]}
        """.data(using: .utf8)!
        let dispatcherModels = [
            BridgedModel(modelID: "big-pickle", baseURL: LocalDispatcher.zenBase)
        ]
        let descriptors = try CodexModelCatalogService.parse(raw, bridgedModels: dispatcherModels)
        XCTAssertTrue(descriptors.contains { $0.modelID == "big-pickle" && $0.providerFamily == .bridged })
    }

    private final class MockFetcher: @unchecked Sendable {
        enum Venue { case success([BridgedModel]); case failure(Error) }
        let venue: Venue
        private let lock = NSLock()
        private var _calls = 0
        var calls: Int { lock.lock(); defer { lock.unlock() }; return _calls }
        init(venue: Venue) { self.venue = venue }
        func fetch() async throws -> [BridgedModel] {
            bumpCalls()
            switch venue {
            case .success(let models): return models
            case .failure(let error): throw error
            }
        }
        private func bumpCalls() {
            lock.lock()
            _calls += 1
            lock.unlock()
        }
    }
}
