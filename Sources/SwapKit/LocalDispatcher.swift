import Foundation
import CryptoKit
import AsyncHTTPClient
import NIOCore
import NIOPosix

// MARK: - Local opencode dispatcher
//
// The opencode CLI's own transport on this machine listens on 127.0.0.1:58444
// and serves three wire surfaces:
//   GET  /zen/v1/models        – OpenAI-style model list
//   POST /zen/v1/chat/completions – Chat Completions wire (model ids may be
//                                   substituted per-route by the dispatcher)
//   POST /codex/responses      – native Responses wire; preserves the caller's
//                                model id byte-for-byte, which is what Codex
//                                speaks.
//
// Every request needs a valid client session identity (`x-opencode-session`);
// the dispatcher normalizes `x-opencode-client` / `x-opencode-request` itself
// and defaults the bearer credential to the public free tier.
public enum LocalDispatcher {
    public static let port = 58444
    public static let origin = "http://127.0.0.1:\(port)"
    public static let zenBase = "\(origin)/zen/v1"

    /// Deterministic ses_-shaped session id. Affinity needs a stable identity;
    /// the dispatcher normalizes any string to the strict `ses_` + 26 chars form.
    public static func sessionID(forNamespace namespace: String = "codexswap") -> String {
        let digest = SHA256.hash(data: Data(namespace.utf8))
        return "ses_" + digest.map { String(format: "%02x", $0) }.joined().prefix(26)
    }

    /// Headers every bridged request to the dispatcher must carry.
    public static func identityHeaders() -> [String: String] {
        [
            "x-opencode-session": sessionID(),
            "x-opencode-client": "codexswap",
            "x-opencode-request": "req_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(26),
        ]
    }

    /// True when a bridged entry's base URL points at this machine's opencode
    /// dispatcher (loopback host + port 58444).
    public static func isDispatcherBaseURL(_ baseURL: String) -> Bool {
        guard let url = URL(string: baseURL),
              let host = url.host?.lowercased(),
              let port = url.port else { return false }
        let loopback = host == "127.0.0.1" || host == "localhost" || host == "::1"
        return loopback && port == Self.port
    }

    /// Native Responses endpoint for a dispatcher base URL, e.g.
    /// http://127.0.0.1:58444/zen/v1 -> http://127.0.0.1:58444/codex/responses
    public static func responsesURL(forBaseURL baseURL: String) -> URL? {
        guard isDispatcherBaseURL(baseURL),
              let url = URL(string: baseURL), let scheme = url.scheme, let host = url.host else { return nil }
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.port = url.port
        components.path = "/codex/responses"
        return components.url
    }

    /// Chat Completions endpoint for a dispatcher base URL (the OpenAI wire
    /// surface under /zen/v1).
    public static func chatCompletionsURL(forBaseURL baseURL: String) -> URL? {
        guard let url = URL(string: baseURL) else { return nil }
        return url.appendingPathComponent("chat/completions")
    }

    /// Model ids advertised by the local dispatcher, as bridged entries.
    /// Uses a dedicated AsyncHTTPClient (which, unlike URLSession, never
    /// honors HTTP_PROXY/HTTPS_PROXY env vars pointing at the dispatcher).
    public static func fetchModels() async throws -> [BridgedModel] {
        guard let modelsURL = URL(string: "\(origin)/codex/models") else { return [] }
        var request = HTTPClientRequest(url: modelsURL.absoluteString)
        request.method = .GET
        for (name, value) in identityHeaders() {
            request.headers.add(name: name, value: value)
        }
        let response = try await dispatcherHTTPClient.execute(request, timeout: .seconds(10))
        guard response.status == .ok else {
            throw LocalDispatcherError.badResponse
        }
        var buffer = ByteBuffer()
        for try await chunk in response.body {
            buffer.writeImmutableBuffer(chunk)
        }
        let data = Data(buffer: buffer)
        struct Payload: Decodable {
            struct Model: Decodable { let id: String }
            let data: [Model]
        }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        return payload.data.map { model in
            BridgedModel(
                modelID: model.id,
                displayName: model.id,
                baseURL: zenBase,
                enabled: true
            )
        }
    }

    private static let dispatcherHTTPClient: HTTPClient = {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        return HTTPClient(
            eventLoopGroupProvider: .shared(group),
            configuration: HTTPClient.Configuration()
        )
    }()

    enum LocalDispatcherError: Error {
        case badResponse
    }
}

/// Process-wide cache of dispatcher-advertised models. The proxy's matcher and
/// the model-catalog service both consult this so discovered opencode models
/// route correctly without waiting on a settings write.
public final class LocalDispatcherRegistry: @unchecked Sendable {
    public static let shared = LocalDispatcherRegistry()

    private let lock = NSLock()
    private var cached: [BridgedModel] = []
    private var lastRefresh: Date?
    private let fetcher: @Sendable () async throws -> [BridgedModel]

    public init(fetcher: @escaping @Sendable () async throws -> [BridgedModel] = { try await LocalDispatcher.fetchModels() }) {
        self.fetcher = fetcher
    }

    /// Cached snapshot; never blocks on the network.
    public func snapshot() -> [BridgedModel] {
        lock.lock()
        defer { lock.unlock() }
        return cached
    }

    /// Refreshes when the cache is older than `maxAge`; returns the freshest
    /// known set on failure (stale or empty).
    @discardableResult
    public func refreshIfStale(maxAge: TimeInterval = 60) async -> [BridgedModel] {
        let stale: Bool = {
            lock.lock()
            defer { lock.unlock() }
            guard let lastRefresh else { return true }
            return Date().timeIntervalSince(lastRefresh) > maxAge
        }()
        guard stale else { return snapshot() }
        do {
            let models = try await fetcher()
            store(models)
        } catch {
            // Keep the previous snapshot; the bridged lane must not lose its
            // catalog when the dispatcher is briefly unreachable.
        }
        return snapshot()
    }

    private func store(_ models: [BridgedModel]) {
        lock.lock()
        cached = models
        lastRefresh = Date()
        lock.unlock()
    }

    func lastRefreshDate() -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return lastRefresh
    }
}
