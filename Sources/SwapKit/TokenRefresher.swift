import Foundation

public enum RefreshError: Error, Sendable, Equatable {
    case missingRefreshToken
    case sessionInvalidated
    case http(Int)
    case malformed
}

public struct TokenRefresher: Sendable {
    public static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    public static let endpoint = URL(string: "https://auth.openai.com/oauth/token")!

    private let session: URLSession
    private let url: URL

    public init(session: URLSession = .shared, url: URL = TokenRefresher.endpoint) {
        self.session = session
        self.url = url
    }

    public func refresh(refreshToken: String) async throws -> CodexTokens {
        guard !refreshToken.isEmpty else { throw RefreshError.missingRefreshToken }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 30
        let body: [String: String] = [
            "client_id": Self.clientID,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw RefreshError.malformed }
        guard http.statusCode == 200 else {
            if let code = Self.errorCode(data), ["refresh_token_expired", "refresh_token_reused", "refresh_token_invalidated"].contains(code) {
                throw RefreshError.sessionInvalidated
            }
            if http.statusCode == 401 { throw RefreshError.sessionInvalidated }
            throw RefreshError.http(http.statusCode)
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = obj["access_token"] as? String, !access.isEmpty else {
            throw RefreshError.malformed
        }
        let idTok = obj["id_token"] as? String ?? ""
        let newRefresh = (obj["refresh_token"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? refreshToken
        let accountId = JWT.identity(fromAccessToken: access).accountID ?? ""
        return CodexTokens(idToken: idTok, accessToken: access, refreshToken: newRefresh, accountId: accountId)
    }

    static func errorCode(_ data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let err = obj["error"] as? [String: Any], let code = err["code"] as? String { return code }
        if let code = obj["error"] as? String { return code }
        return nil
    }
}
