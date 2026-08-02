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
        return try Self.parseStrict(data)
    }

    static func parse(_ data: Data) -> [UsageWindow] {
        (try? parseStrict(data)) ?? []
    }

    private static func parseStrict(_ data: Data) throws -> [UsageWindow] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rate = obj["rate_limit"] as? [String: Any] else {
            throw UsageError.malformed
        }

        var windows: [UsageWindow] = []
        for key in ["primary_window", "secondary_window"] {
            guard let rawWindow = rate[key] else { continue }
            if rawWindow is NSNull { continue }
            guard let w = rawWindow as? [String: Any],
                  let seconds = integerValue(w["limit_window_seconds"]),
                  let percent = integerValue(w["used_percent"]) else {
                throw UsageError.malformed
            }

            var reset: Date?
            if let rawReset = w["reset_at"], !(rawReset is NSNull) {
                guard let resetRaw = integerValue(rawReset) else { throw UsageError.malformed }
                reset = resetRaw > 0 ? Date(timeIntervalSince1970: TimeInterval(resetRaw)) : nil
            } else {
                reset = nil
            }
            windows.append(UsageWindow(label: UsageWindow.label(forWindowSeconds: seconds), usedPercent: percent, windowSeconds: seconds, resetAt: reset))
        }

        guard !windows.isEmpty else { throw UsageError.malformed }
        return windows
    }

    private static func integerValue(_ raw: Any?) -> Int? {
        if let value = raw as? Int { return value }
        if let value = raw as? Double, value.isFinite, value.rounded() == value {
            return Int(exactly: value)
        }
        return nil
    }
}
