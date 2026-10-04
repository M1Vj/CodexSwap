import Foundation
import AsyncHTTPClient

/// Live roster of the opencode-indefinite dispatcher. The dispatcher needs no
/// OAuth from its callers: it manufactures its own credential and only asks for
/// x-opencode-* identity headers used purely for session affinity.
public struct DispatcherUpstream: Sendable {
    public static let defaultBaseURL = "http://127.0.0.1:58444"

    public let baseURL: String

    public init(baseURL: String = DispatcherUpstream.defaultBaseURL) {
        self.baseURL = baseURL
    }

    /// Identity headers the dispatcher expects on every call.
    public static func identityHeaders(sessionID: String = defaultSessionID, client: String = "codexswap") -> [String: String] {
        [
            "x-opencode-session": sessionID,
            "x-opencode-client": client,
            "x-opencode-request": UUID().uuidString,
            "x-opencode-project": client,
        ]
    }

    /// Stable per-process session affinity; the daemon's only hard requirement is the
    /// `ses_` prefix plus 26 alphanumerics.
    public static let defaultSessionID: String = {
        let raw = UUID().uuidString.replacingOccurrences(of: "-", with: "") + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        return "ses_" + String(raw.prefix(26))
    }()

    /// Fetches the dispatcher's truthful model roster and maps it to bridged,
    /// responses-passthrough entries. Returns an empty list on any failure so the
    /// codex lane is never degraded.
    public func models(httpClient: HTTPClient) async -> [BridgedModel] {
        guard let base = BridgedModel.validatedBaseURL(baseURL) else { return [] }
        var request = HTTPClientRequest(url: base.appendingPathComponent("codex/models").absoluteString)
        request.method = .GET
        for (name, value) in Self.identityHeaders() {
            request.headers.add(name: name, value: value)
        }
        do {
            let response = try await httpClient.execute(request, timeout: .seconds(15))
            guard response.status == .ok else { return [] }
            let body = try await response.body.collect(upTo: 8 * 1024 * 1024)
            return Self.parseModels(body: Data(buffer: body), baseURL: baseURL)
        } catch {
            return []
        }
    }

    public static func parseModels(body: Data, baseURL: String) -> [BridgedModel] {
        guard
            let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
            let data = object["data"] as? [[String: Any]]
        else { return [] }
        return data.compactMap { entry in
            guard let id = entry["id"] as? String, !id.isEmpty else { return nil }
            return BridgedModel(
                modelID: id,
                displayName: id,
                baseURL: baseURL,
                upstream: .responsesPassthrough
            )
        }
    }

    /// Merges dispatcher-origin slugs into the upstream codex catalog JSON
    /// (`{"models":[...]}`). Genuine entries pass through untouched; each
    /// dispatcher slug clones the first genuine entry's field shape with `slug`
    /// replaced, which is the shape Codex already consumes. Duplicates win for
    /// the genuine entry.
    public static func mergingDispatcherSlugs(
        upstreamCatalogBody: Data,
        dispatcherModels: [BridgedModel]
    ) -> Data? {
        guard
            var root = try? JSONSerialization.jsonObject(with: upstreamCatalogBody) as? [String: Any],
            var models = root["models"] as? [[String: Any]],
            !models.isEmpty
        else { return nil }
        let existing = Set(models.compactMap { $0["slug"] as? String })
        var added: [String] = []
        for entry in dispatcherModels where entry.enabled {
            if existing.contains(entry.modelID) { continue }
            var clone = models[0]
            clone["slug"] = entry.modelID
            models.append(clone)
            added.append(entry.modelID)
        }
        root["models"] = models
        return try? JSONSerialization.data(withJSONObject: root)
    }
}

/// Caches the genuine codex slug set (from `codex debug models`) for one cache window
/// so dispatcher-origin routing never shadows a codex model.
actor CodexCatalogSlugCache {
    static let shared = CodexCatalogSlugCache()
    private var cached: (fetchedAt: Date, slugs: Set<String>)?

    private init() {}

    func slugs() async -> Set<String> {
        if let cached, Date().timeIntervalSince(cached.fetchedAt) < 60 {
            return cached.slugs
        }
        do {
            let descriptors = try await CodexModelCatalogService().load()
            let slugs = Set(descriptors.map(\.modelID))
            cached = (Date(), slugs)
            return slugs
        } catch {
            return cached?.slugs ?? []
        }
    }
}

/// TTL-cached facade so each request does not refetch the dispatcher roster.
public actor DispatcherCatalogCache {
    public static let shared = DispatcherCatalogCache()

    private var cached: [BridgedModel] = []
    private var cachedAt: Date?
    private let ttlSeconds: TimeInterval
    private let upstream: DispatcherUpstream

    public init(ttlSeconds: TimeInterval = 60, upstream: DispatcherUpstream = DispatcherUpstream()) {
        self.ttlSeconds = ttlSeconds
        self.upstream = upstream
    }

    public func models(httpClient: HTTPClient) async -> [BridgedModel] {
        if let cachedAt, Date().timeIntervalSince(cachedAt) < ttlSeconds {
            return cached
        }
        let fresh = await upstream.models(httpClient: httpClient)
        cached = fresh
        cachedAt = Date()
        return fresh
    }

    /// Merged bridged catalog: user-declared bridged models plus the live
    /// dispatcher roster, minus any slug the genuine codex catalog already
    /// serves so codex account routing always wins collisions.
    public func mergedBridgedModels(
        settings: Settings,
        httpClient: HTTPClient
    ) async -> [BridgedModel] {
        let dispatcher = await models(httpClient: httpClient)
        let codexSlugs = await CodexCatalogSlugCache.shared.slugs()
        return settings.bridgedModels + dispatcher.filter { !codexSlugs.contains($0.modelID) }
    }
}
