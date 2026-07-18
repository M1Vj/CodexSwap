import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct ResetCredit: Sendable, Equatable {
    public let id: String
    public let resetType: String
    public let status: String
    public let grantedAt: Date
    public let expiresAt: Date?
    public let title: String?
    public let description: String?

    public var isAvailable: Bool { status == "available" }

    public init(id: String, resetType: String, status: String, grantedAt: Date, expiresAt: Date? = nil, title: String? = nil, description: String? = nil) {
        self.id = id
        self.resetType = resetType
        self.status = status
        self.grantedAt = grantedAt
        self.expiresAt = expiresAt
        self.title = title
        self.description = description
    }
}

public struct ResetCreditSnapshot: Sendable, Equatable {
    public let availableCount: Int
    public let totalEarnedCount: Int?
    public let credits: [ResetCredit]
    public let fetchedAt: Date

    public var earliestAvailable: ResetCredit? {
        credits.filter(\.isAvailable).min { lhs, rhs in
            switch (lhs.expiresAt, rhs.expiresAt) {
            case let (left?, right?): left == right ? lhs.id < rhs.id : left < right
            case (_?, nil): true
            case (nil, _?): false
            case (nil, nil): lhs.id < rhs.id
            }
        }
    }

    public init(availableCount: Int, totalEarnedCount: Int? = nil, credits: [ResetCredit], fetchedAt: Date) {
        self.availableCount = availableCount
        self.totalEarnedCount = totalEarnedCount
        self.credits = credits
        self.fetchedAt = fetchedAt
    }
}

public enum ResetConsumeOutcome: String, Sendable, Equatable {
    case reset
    case nothingToReset = "nothing_to_reset"
    case noCredit = "no_credit"
    case alreadyRedeemed = "already_redeemed"
}

public struct ResetConsumeResult: Sendable, Equatable {
    public let outcome: ResetConsumeOutcome
    public let windowsReset: Int

    public init(outcome: ResetConsumeOutcome, windowsReset: Int) {
        self.outcome = outcome
        self.windowsReset = windowsReset
    }
}

public enum QuotaResetTransportCategory: Sendable, Equatable {
    case timeout
    case network
}

public enum QuotaResetClientError: Error, Sendable, Equatable {
    case invalidRequest
    case unauthorized
    case httpStatus(Int)
    case transport(QuotaResetTransportCategory)
    case malformedResponse
}

public protocol QuotaResetServing: Sendable {
    func credits(accessToken: String, accountID: String) async throws -> ResetCreditSnapshot
    func consume(accessToken: String, accountID: String, creditID: String, redemptionID: UUID) async throws -> ResetConsumeResult
}

public struct QuotaResetClient: QuotaResetServing, Sendable {
    public static let defaultCreditsEndpoint = URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits")!
    public static let defaultConsumeEndpoint = URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits/consume")!

    private let dataLoader: @Sendable (URLRequest) async throws -> (Data, URLResponse)

    public init() {
        self.init(ownedSessionDidBecomeInvalid: {}, ownedSessionOwnerDidDeinit: {})
    }

    init(
        ownedSessionDidBecomeInvalid: @escaping @Sendable () -> Void,
        ownedSessionOwnerDidDeinit: @escaping @Sendable () -> Void
    ) {
        let sessionOwner = QuotaResetSessionOwner(
            sessionDidBecomeInvalid: ownedSessionDidBecomeInvalid,
            onDeinit: ownedSessionOwnerDidDeinit
        )
        self.dataLoader = { try await sessionOwner.session.data(for: $0) }
    }

    init(session: URLSession) {
        self.dataLoader = { try await session.data(for: $0) }
    }

    init(dataLoader: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse)) {
        self.dataLoader = dataLoader
    }

    public func credits(accessToken: String, accountID: String) async throws -> ResetCreditSnapshot {
        let token = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw QuotaResetClientError.invalidRequest }
        var request = request(url: Self.defaultCreditsEndpoint, method: "GET", accessToken: token, accountID: accountID)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data = try await perform(request)
        do {
            let payload = try JSONDecoder().decode(CreditsPayload.self, from: data)
            let credits = try payload.credits.map { dto -> ResetCredit in
                guard !dto.id.isEmpty, !dto.resetType.isEmpty, !dto.status.isEmpty,
                      let grantedAt = Self.parseDate(dto.grantedAt) else { throw QuotaResetClientError.malformedResponse }
                let expiresAt: Date?
                if let raw = dto.expiresAt {
                    guard let parsed = Self.parseDate(raw) else { throw QuotaResetClientError.malformedResponse }
                    expiresAt = parsed
                } else { expiresAt = nil }
                return ResetCredit(id: dto.id, resetType: dto.resetType, status: dto.status, grantedAt: grantedAt, expiresAt: expiresAt, title: dto.title, description: dto.description)
            }
            guard payload.availableCount >= 0, payload.totalEarnedCount.map({ $0 >= 0 }) ?? true else {
                throw QuotaResetClientError.malformedResponse
            }
            let actualAvailableCount = credits.lazy.filter(\.isAvailable).count
            return ResetCreditSnapshot(availableCount: min(payload.availableCount, actualAvailableCount), totalEarnedCount: payload.totalEarnedCount, credits: credits, fetchedAt: Date())
        } catch let error as QuotaResetClientError { throw error }
        catch { throw QuotaResetClientError.malformedResponse }
    }

    public func consume(accessToken: String, accountID: String, creditID: String, redemptionID: UUID) async throws -> ResetConsumeResult {
        let token = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedCreditID = creditID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, !normalizedCreditID.isEmpty else { throw QuotaResetClientError.invalidRequest }
        var request = request(url: Self.defaultConsumeEndpoint, method: "POST", accessToken: token, accountID: accountID)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do { request.httpBody = try JSONEncoder().encode(ConsumeRequest(redeemRequestID: redemptionID.uuidString, creditID: normalizedCreditID)) }
        catch { throw QuotaResetClientError.malformedResponse }
        let data = try await perform(request)
        do {
            let payload = try JSONDecoder().decode(ConsumePayload.self, from: data)
            guard let outcome = ResetConsumeOutcome(rawValue: payload.code), payload.windowsReset >= 0 else { throw QuotaResetClientError.malformedResponse }
            return ResetConsumeResult(outcome: outcome, windowsReset: payload.windowsReset)
        } catch let error as QuotaResetClientError { throw error }
        catch { throw QuotaResetClientError.malformedResponse }
    }

    private func request(url: URL, method: String, accessToken: String, accountID: String) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = method
        request.setValue("CodexSwap/QuotaResetClient", forHTTPHeaderField: "User-Agent")
        if !accessToken.isEmpty { request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization") }
        let normalizedAccountID = accountID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalizedAccountID.isEmpty { request.setValue(normalizedAccountID, forHTTPHeaderField: "ChatGPT-Account-Id") }
        return request
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        do {
            let (data, response) = try await dataLoader(request)
            guard let http = response as? HTTPURLResponse else { throw QuotaResetClientError.malformedResponse }
            guard let finalURL = http.url, Self.isAllowedOrigin(finalURL) else {
                throw QuotaResetClientError.invalidRequest
            }
            guard http.statusCode != 401 else { throw QuotaResetClientError.unauthorized }
            guard (200..<300).contains(http.statusCode) else { throw QuotaResetClientError.httpStatus(http.statusCode) }
            return data
        } catch let error as QuotaResetClientError { throw error }
        catch is CancellationError { throw CancellationError() }
        catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw QuotaResetClientError.transport(error.code == .timedOut ? .timeout : .network)
        }
        catch {
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain, nsError.code == URLError.cancelled.rawValue {
                throw CancellationError()
            }
            throw QuotaResetClientError.transport(.network)
        }
    }

    private static func parseDate(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    fileprivate static func isAllowedOrigin(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", url.host?.lowercased() == "chatgpt.com" else { return false }
        return url.port == nil || url.port == 443
    }
}

private final class QuotaResetSessionOwner: @unchecked Sendable {
    let session: URLSession
    private let onDeinit: @Sendable () -> Void

    init(
        sessionDidBecomeInvalid: @escaping @Sendable () -> Void,
        onDeinit: @escaping @Sendable () -> Void
    ) {
        self.onDeinit = onDeinit
        session = URLSession(
            configuration: .ephemeral,
            delegate: QuotaResetRedirectDelegate(onSessionInvalidated: sessionDidBecomeInvalid),
            delegateQueue: nil
        )
    }

    deinit {
        session.invalidateAndCancel()
        onDeinit()
    }
}

final class QuotaResetRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
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

private struct CreditsPayload: Decodable {
    let availableCount: Int
    let totalEarnedCount: Int?
    let credits: [CreditPayload]
    enum CodingKeys: String, CodingKey { case availableCount = "available_count", totalEarnedCount = "total_earned_count", credits }
}

private struct CreditPayload: Decodable {
    let id: String
    let resetType: String
    let status: String
    let grantedAt: String
    let expiresAt: String?
    let title: String?
    let description: String?
    enum CodingKeys: String, CodingKey { case id, resetType = "reset_type", status, grantedAt = "granted_at", expiresAt = "expires_at", title, description }
}

private struct ConsumeRequest: Encodable {
    let redeemRequestID: String
    let creditID: String
    enum CodingKeys: String, CodingKey { case redeemRequestID = "redeem_request_id", creditID = "credit_id" }
}

private struct ConsumePayload: Decodable {
    let code: String
    let windowsReset: Int
    enum CodingKeys: String, CodingKey { case code, windowsReset = "windows_reset" }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        code = try container.decode(String.self, forKey: .code)
        windowsReset = try container.decodeIfPresent(Int.self, forKey: .windowsReset) ?? 0
    }
}
