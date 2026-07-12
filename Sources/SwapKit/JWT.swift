import Foundation

/// Minimal, unverified decode of a JWT payload. Identity/expiry only — never a trust decision.
public enum JWT {
    public static func payload(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        guard let data = base64URLDecode(String(parts[1])) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    public static func expiry(_ token: String) -> Date? {
        guard let claims = payload(token) else { return nil }
        guard let exp = numeric(claims["exp"]) else { return nil }
        return Date(timeIntervalSince1970: exp)
    }

    /// JWT numeric claims may arrive as Int, Double, or String depending on the issuer.
    static func numeric(_ value: Any?) -> Double? {
        switch value {
        case let d as Double: return d
        case let i as Int: return Double(i)
        case let s as String: return Double(s)
        default: return nil
        }
    }

    /// True when the access token is missing, unparseable, or within `skew` of expiry.
    public static func isStale(_ token: String, now: Date = Date(), skew: TimeInterval = 30) -> Bool {
        guard let exp = expiry(token) else { return true }
        return exp.timeIntervalSince(now) <= skew
    }

    public struct Identity: Sendable {
        public var accountID: String?
        public var email: String?
        public var planType: String?
    }

    public static func identity(fromAccessToken token: String) -> Identity {
        let claims = payload(token) ?? [:]
        let authClaims = claims["https://api.openai.com/auth"] as? [String: Any]
        let profileClaims = claims["https://api.openai.com/profile"] as? [String: Any]
        let accountID = (claims["https://api.openai.com/auth_account_id"] as? String)
            ?? (authClaims?["chatgpt_account_id"] as? String)
            ?? (claims["chatgpt_account_id"] as? String)
            ?? (claims["account_id"] as? String)
        let email = (profileClaims?["email"] as? String)
            ?? (claims["email"] as? String)
            ?? (claims["https://api.openai.com/email"] as? String)
        let planType = (claims["chatgpt_plan_type"] as? String)
            ?? (authClaims?["chatgpt_plan_type"] as? String)
            ?? (claims["https://api.openai.com/plan_type"] as? String)
        return Identity(accountID: accountID, email: email, planType: planType)
    }

    static func base64URLDecode(_ s: String) -> Data? {
        var b64 = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let pad = b64.count % 4
        if pad != 0 { b64 += String(repeating: "=", count: 4 - pad) }
        return Data(base64Encoded: b64)
    }
}
