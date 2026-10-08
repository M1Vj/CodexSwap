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
        let chatBase = chatCompletionsBaseURL(from: baseURL)
        return data.compactMap { entry in
            guard let id = entry["id"] as? String, !id.isEmpty else { return nil }
            return BridgedModel(
                modelID: id,
                displayName: id,
                baseURL: chatBase,
                upstream: .chatCompletions
            )
        }
    }

    /// Chat-Completions base for dispatcher entries. The dispatcher serves chat
    /// at `/zen/v1/chat/completions`, while `baseURL` points at the dispatcher
    /// root, so entries carry the versioned base the bridge appends to.
    /// Every dispatcher model is reachable over chat (chat-only models only
    /// over chat), so entries use the translation wire; the bridge translates
    /// Codex Responses requests with the caller's tools/prompts only.
    public static func chatCompletionsBaseURL(from baseURL: String) -> String {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if trimmed.hasSuffix("/zen/v1") { return trimmed }
        return trimmed + "/zen/v1"
    }

    /// True when an entry points at the local dispatcher, which requires the
    /// `x-opencode-*` session identity headers on every call.
    public static func isDispatcherEntry(_ entry: BridgedModel) -> Bool {
        guard let url = BridgedModel.validatedBaseURL(entry.baseURL),
              let host = url.host?.lowercased(),
              url.port == 58444
        else { return false }
        if host == "localhost" || host == "::1" { return true }
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4, octets[0] == "127" else { return false }
        return octets.dropFirst().allSatisfy { part in
            !part.isEmpty && part.allSatisfy(\.isNumber)
        }
    }

    /// Merges dispatcher-origin slugs into the upstream codex catalog JSON
    /// (`{"models":[...]}`). Genuine entries pass through untouched; each
    /// dispatcher slug clones a genuinely listed entry's field shape with
    /// `slug` replaced and `visibility`/`list` forced selectable, which is the
    /// shape Codex already consumes. Duplicates win for the genuine entry.
    static func isListedCatalogEntry(_ entry: [String: Any]) -> Bool {
        guard (entry["visibility"] as? String) == "list" else { return false }
        // The backend-api models schema carries `list: null` even on listed
        // entries (verified live: gpt-5.6-sol is visibility list with null
        // list); only an explicit false means unlisted.
        if let listed = entry["list"] as? Bool { return listed }
        return true
    }

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
        let template = models.first(where: isListedCatalogEntry) ?? models[0]
        var added: [String] = []
        for entry in dispatcherModels where entry.enabled {
            if existing.contains(entry.modelID) { continue }
            var clone = template
            clone["slug"] = entry.modelID
            clone["visibility"] = "list"
            clone["list"] = true
            models.append(clone)
            added.append(entry.modelID)
        }
        root["models"] = models
        return try? JSONSerialization.data(withJSONObject: root)
    }
}

/// Caches the genuine codex slug set (from `codex debug models`) so dispatcher-origin
/// routing never shadows a codex model.
actor CodexCatalogSlugCache {
    typealias Loader = @Sendable () async throws -> Set<String>

    private enum LoadOutcome: Sendable {
        case loaded(Set<String>)
        case failed
        case cancelled
    }

    static let shared = CodexCatalogSlugCache()

    private let loader: Loader
    private let refreshInterval: TimeInterval
    private let maximumStaleness: TimeInterval
    private let now: @Sendable () -> Date
    private var lastSuccess: (fetchedAt: Date, slugs: Set<String>)?
    private var lastAttemptAt: Date?
    private var inFlight: Task<LoadOutcome, Never>?

    init(
        refreshInterval: TimeInterval = 60,
        maximumStaleness: TimeInterval = 600,
        now: @escaping @Sendable () -> Date = { Date() },
        loader: @escaping Loader = { try await CodexModelCatalogService().loadSlugs() }
    ) {
        self.refreshInterval = refreshInterval
        self.maximumStaleness = maximumStaleness
        self.now = now
        self.loader = loader
    }

    /// Failed loads back off for one refresh interval so a broken `codex` launch is
    /// not respawned per request, while the last good set ages out after
    /// `maximumStaleness` so slugs added by a Codex upgrade cannot stay shadowed.
    func slugs() async -> Set<String> {
        if let lastAttemptAt, now().timeIntervalSince(lastAttemptAt) < refreshInterval {
            return usableSlugs()
        }
        let task = startLoadIfNeeded()
        record(await task.value, from: task)
        return usableSlugs()
    }

    /// Non-blocking read for the `/models` endpoint. `codex debug models` may refresh
    /// its catalog through this proxy, so while a discovery runs `/models` gets no
    /// dispatcher entries; otherwise they would be recorded as genuine codex slugs.
    func peekSlugs() -> Set<String> {
        guard inFlight == nil else { return [] }
        let isDue = lastAttemptAt.map { now().timeIntervalSince($0) >= refreshInterval } ?? true
        if isDue {
            let task = startLoadIfNeeded()
            Task { record(await task.value, from: task) }
        }
        return usableSlugs()
    }

    /// The load belongs to the cache rather than to whichever request started it, so a
    /// cancelled caller cannot abort discovery for callers still waiting on it; the
    /// subprocess is bounded by its own command timeout.
    private func startLoadIfNeeded() -> Task<LoadOutcome, Never> {
        if let inFlight { return inFlight }
        let loader = self.loader
        let task = Task<LoadOutcome, Never> {
            do {
                return .loaded(try await loader())
            } catch is CancellationError {
                return .cancelled
            } catch {
                return .failed
            }
        }
        inFlight = task
        return task
    }

    /// Joined callers can resume before the caller that started the load, so whichever
    /// resumes first records the outcome, exactly once per load.
    private func record(_ outcome: LoadOutcome, from task: Task<LoadOutcome, Never>) {
        guard inFlight == task else { return }
        inFlight = nil
        switch outcome {
        case .loaded(let slugs):
            lastSuccess = (now(), slugs)
            lastAttemptAt = now()
        case .failed:
            lastAttemptAt = now()
        case .cancelled:
            break
        }
    }

    private func usableSlugs() -> Set<String> {
        guard let lastSuccess,
              now().timeIntervalSince(lastSuccess.fetchedAt) < maximumStaleness
        else { return [] }
        return lastSuccess.slugs
    }
}

/// TTL-cached facade so each request does not refetch the dispatcher roster.
public actor DispatcherCatalogCache {
    public static let shared = DispatcherCatalogCache()

    private var cached: [BridgedModel] = []
    private var cachedAt: Date?
    private let ttlSeconds: TimeInterval
    private let upstream: DispatcherUpstream
    private let codexSlugs: CodexCatalogSlugCache

    public init(ttlSeconds: TimeInterval = 60, upstream: DispatcherUpstream = DispatcherUpstream()) {
        self.init(ttlSeconds: ttlSeconds, upstream: upstream, codexSlugs: .shared)
    }

    init(ttlSeconds: TimeInterval, upstream: DispatcherUpstream, codexSlugs: CodexCatalogSlugCache) {
        self.ttlSeconds = ttlSeconds
        self.upstream = upstream
        self.codexSlugs = codexSlugs
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

    /// Merged bridged catalog: user-declared bridged models plus the routable
    /// dispatcher roster (see `routableBridgedModels`).
    public func mergedBridgedModels(
        settings: Settings,
        httpClient: HTTPClient
    ) async -> [BridgedModel] {
        let dispatcher = await models(httpClient: httpClient)
        return Self.routableBridgedModels(
            declared: settings.bridgedModels,
            dispatcher: dispatcher,
            codexSlugs: await codexSlugs.slugs()
        )
    }

    /// Dispatcher entries safe to advertise in `/models`, kept identical to the
    /// routable set so Codex never lists a model the proxy would not route.
    public func routableDispatcherModels(httpClient: HTTPClient) async -> [BridgedModel] {
        let dispatcher = await models(httpClient: httpClient)
        return Self.routableBridgedModels(
            declared: [],
            dispatcher: dispatcher,
            codexSlugs: await codexSlugs.peekSlugs()
        )
    }

    /// Codex slugs win collisions, and the dispatcher fails closed: without a known
    /// codex slug set its roster (which mirrors codex slugs such as `gpt-6.1-sol`)
    /// would hijack codex traffic away from account routing and Responses-only
    /// features like remote compaction.
    static func routableBridgedModels(
        declared: [BridgedModel],
        dispatcher: [BridgedModel],
        codexSlugs: Set<String>
    ) -> [BridgedModel] {
        guard !codexSlugs.isEmpty else { return declared }
        return declared + dispatcher.filter { !codexSlugs.contains($0.modelID) }
    }
}
