import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public protocol UsageFetching: Sendable {
    func fetch(accessToken: String, accountID: String) async throws -> [UsageWindow]
}

public struct UsageClient: UsageFetching, Sendable {
    public static let endpoint = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    public static let userAgent = "codex-swap/0.1"

    private let session: URLSession
    private let url: URL
    private let sessionOwner: UsageSessionOwner?

    public init(url: URL = UsageClient.endpoint) {
        let sessionOwner = UsageSessionOwner(sessionDidBecomeInvalid: {}, onDeinit: {})
        self.session = sessionOwner.session
        self.url = url
        self.sessionOwner = sessionOwner
    }

    public init(session: URLSession, url: URL = UsageClient.endpoint) {
        self.session = session
        self.url = url
        self.sessionOwner = nil
    }

    init(
        ownedSessionDidBecomeInvalid: @escaping @Sendable () -> Void,
        ownedSessionOwnerDidDeinit: @escaping @Sendable () -> Void,
        url: URL = UsageClient.endpoint
    ) {
        let sessionOwner = UsageSessionOwner(
            sessionDidBecomeInvalid: ownedSessionDidBecomeInvalid,
            onDeinit: ownedSessionOwnerDidDeinit
        )
        self.session = sessionOwner.session
        self.url = url
        self.sessionOwner = sessionOwner
    }

    var configurationForTesting: URLSessionConfiguration { session.configuration }

    public enum UsageError: Error, Sendable { case unauthorized, http(Int), malformed }

    public func fetch(accessToken: String, accountID: String) async throws -> [UsageWindow] {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 20
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.setValue("application/json", forHTTPHeaderField: "Accept")
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

private final class UsageSessionOwner: @unchecked Sendable {
    let session: URLSession
    private let onDeinit: @Sendable () -> Void

    init(
        sessionDidBecomeInvalid: @escaping @Sendable () -> Void,
        onDeinit: @escaping @Sendable () -> Void
    ) {
        self.onDeinit = onDeinit
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        session = URLSession(
            configuration: configuration,
            delegate: UsageRedirectDelegate(onSessionInvalidated: sessionDidBecomeInvalid),
            delegateQueue: nil
        )
    }

    deinit {
        session.invalidateAndCancel()
        onDeinit()
    }
}

final class UsageRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let onSessionInvalidated: @Sendable () -> Void

    init(onSessionInvalidated: @escaping @Sendable () -> Void = {}) {
        self.onSessionInvalidated = onSessionInvalidated
    }

    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
        onSessionInvalidated()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
