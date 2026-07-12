import Foundation

public protocol UsageFetching: Sendable {
    func fetch(accessToken: String, accountID: String) async throws -> [UsageWindow]
}

public struct UsageClient: UsageFetching, Sendable {
    public static let endpoint = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    public static let userAgent = "codex-swap/0.1"

    private let session: URLSession
    private let url: URL

    public init(session: URLSession = .shared, url: URL = UsageClient.endpoint) {
        self.session = session
        self.url = url
    }

    public enum UsageError: Error, Sendable { case unauthorized, http(Int), malformed }

    public func fetch(accessToken: String, accountID: String) async throws -> [UsageWindow] {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 20
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        if !accountID.isEmpty { req.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id") }
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw UsageError.malformed }
        if http.statusCode == 401 { throw UsageError.unauthorized }
        guard http.statusCode == 200 else { throw UsageError.http(http.statusCode) }
        return Self.parse(data)
    }

    static func parse(_ data: Data) -> [UsageWindow] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rate = obj["rate_limit"] as? [String: Any] else { return [] }
        var windows: [UsageWindow] = []
        for key in ["primary_window", "secondary_window"] {
            guard let w = rate[key] as? [String: Any] else { continue }
            let seconds = (w["limit_window_seconds"] as? Int) ?? Int((w["limit_window_seconds"] as? Double) ?? 0)
            let percent = (w["used_percent"] as? Int) ?? Int((w["used_percent"] as? Double) ?? 0)
            let resetRaw = (w["reset_at"] as? Int) ?? Int((w["reset_at"] as? Double) ?? 0)
            let reset = resetRaw > 0 ? Date(timeIntervalSince1970: TimeInterval(resetRaw)) : nil
            windows.append(UsageWindow(label: UsageWindow.label(forWindowSeconds: seconds), usedPercent: percent, windowSeconds: seconds, resetAt: reset))
        }
        return windows
    }
}
