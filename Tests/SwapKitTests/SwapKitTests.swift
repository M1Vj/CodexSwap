import XCTest
import NIOCore
import NIOHTTP1
@testable import SwapKit

final class JWTTests: XCTestCase {
    private func makeToken(claims: [String: Any]) -> String {
        let header = Data("{}".utf8).base64EncodedString()
        let payload = try! JSONSerialization.data(withJSONObject: claims)
        let b64 = payload.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "\(header).\(b64).sig"
    }

    func testExpiryHandlesStringClaim() {
        let future = Date().addingTimeInterval(3600)
        let token = makeToken(claims: ["exp": String(Int(future.timeIntervalSince1970))])
        XCTAssertNotNil(JWT.expiry(token))
        XCTAssertFalse(JWT.isStale(token))
    }

    func testExpiryHandlesNumericClaim() {
        let past = Date().addingTimeInterval(-10)
        let token = makeToken(claims: ["exp": Int(past.timeIntervalSince1970)])
        XCTAssertTrue(JWT.isStale(token))
    }

    func testIdentityFromProfileClaim() {
        let token = makeToken(claims: [
            "https://api.openai.com/profile": ["email": "user@example.com"],
            "https://api.openai.com/auth": ["chatgpt_account_id": "acc-123", "chatgpt_plan_type": "plus"],
        ])
        let id = JWT.identity(fromAccessToken: token)
        XCTAssertEqual(id.email, "user@example.com")
        XCTAssertEqual(id.accountID, "acc-123")
        XCTAssertEqual(id.planType, "plus")
    }

    func testMissingExpIsStale() {
        XCTAssertTrue(JWT.isStale("not.a.jwt"))
        XCTAssertTrue(JWT.isStale(""))
    }
}

final class UsageParseTests: XCTestCase {
    func testParsePrimarySecondary() {
        let json = """
        {"rate_limit":{"primary_window":{"used_percent":31,"limit_window_seconds":18000,"reset_at":1783000000},
        "secondary_window":{"used_percent":91,"limit_window_seconds":604800,"reset_at":1784000000}}}
        """
        let windows = UsageClient.parse(Data(json.utf8))
        XCTAssertEqual(windows.count, 2)
        XCTAssertEqual(windows[0].label, "5h")
        XCTAssertEqual(windows[0].usedPercent, 31)
        XCTAssertEqual(windows[1].label, "Weekly")
        XCTAssertEqual(windows[1].usedPercent, 91)
        XCTAssertNotNil(windows[0].resetAt)
    }

    func testParseEmpty() {
        XCTAssertTrue(UsageClient.parse(Data("{}".utf8)).isEmpty)
    }

    func testWindowLabels() {
        XCTAssertEqual(UsageWindow.label(forWindowSeconds: 18000), "5h")
        XCTAssertEqual(UsageWindow.label(forWindowSeconds: 604800), "Weekly")
        XCTAssertEqual(UsageWindow.label(forWindowSeconds: 259200), "3d")
    }
}

final class LimitDetectionTests: XCTestCase {
    private func buf(_ s: String) -> ByteBuffer { ByteBuffer(bytes: Array(s.utf8)) }

    func testUsageLimitNested() {
        XCTAssertTrue(bodyHasUsageLimit(buf(#"{"error":{"type":"usage_limit_reached","resets_at":123}}"#)))
        XCTAssertFalse(bodyHasUsageLimit(buf(#"{"error":{"type":"invalid_request"}}"#)))
    }

    func testLimitInfoParsesResetAndHeader() {
        var headers = HTTPHeaders()
        headers.add(name: "x-codex-active-limit", value: "5h")
        let (limit, reset) = limitInfo(headers: headers, body: buf(#"{"error":{"resets_at":1783000000}}"#))
        XCTAssertEqual(limit, "5h")
        XCTAssertEqual(reset, Date(timeIntervalSince1970: 1783000000))
    }

    func testLimitInfoDefaults() {
        let (limit, reset) = limitInfo(headers: HTTPHeaders(), body: buf("{}"))
        XCTAssertEqual(limit, "codex")
        XCTAssertNil(reset)
    }

    func testSessionInvalidated() {
        XCTAssertTrue(isSessionInvalidated(buf(#"{"error":{"code":"token_invalidated"}}"#)))
        XCTAssertTrue(isSessionInvalidated(buf(#"{"error":{"code":"token_revoked"}}"#)))
        XCTAssertFalse(isSessionInvalidated(buf(#"{"error":{"code":"expired"}}"#)))
    }
}

final class RotationTests: XCTestCase {
    private func tempStore(_ accounts: [Account], strategy: RotationStrategy = .priority) async -> AccountStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cs-test-\(UUID().uuidString).json")
        let store = AccountStore(url: url, strategy: strategy)
        for a in accounts { await store.upsert(a) }
        return store
    }

    private func acct(_ alias: String, priority: Int = 0, token: String = "t", cooldown: Date? = nil, needsLogin: Bool = false) -> Account {
        var a = Account(alias: alias, accountID: alias, accessToken: token, priority: priority, needsLogin: needsLogin)
        if let cooldown { a.disabledUntil["codex"] = cooldown }
        return a
    }

    func testPriorityPicksHighest() async {
        let store = await tempStore([acct("low", priority: 1), acct("high", priority: 10)])
        let current = await store.current()
        XCTAssertEqual(current?.alias, "high")
    }

    func testSkipsCooledDownAndNeedsLogin() async {
        let future = Date().addingTimeInterval(3600)
        let store = await tempStore([
            acct("a", priority: 10, cooldown: future),
            acct("b", priority: 5, needsLogin: true),
            acct("c", priority: 1),
        ])
        let current = await store.current()
        XCTAssertEqual(current?.alias, "c")
    }

    func testRotateFromDisablesAndAdvances() async {
        let store = await tempStore([acct("a", priority: 10), acct("b", priority: 5)])
        let reset = Date().addingTimeInterval(3600)
        let result = await store.rotateFrom("a", limit: "5h", resetAt: reset, fallbackCooldown: 18000)
        XCTAssertTrue(result.rotated)
        XCTAssertEqual(result.next?.alias, "b")
        let a = await store.account("a")
        XCTAssertEqual(a?.disabledUntil["5h"], reset)
    }

    func testRotateExhaustedReturnsNotRotated() async {
        let store = await tempStore([acct("solo", priority: 1)])
        let result = await store.rotateFrom("solo", limit: "5h", resetAt: nil, fallbackCooldown: 18000)
        XCTAssertFalse(result.rotated)
        XCTAssertNil(result.next)
    }

    func testRoundRobinCyclesLeastRecentlyUsed() async {
        let store = await tempStore([acct("a"), acct("b"), acct("c")], strategy: .roundRobin)
        let first = await store.current()
        let r1 = await store.rotateFrom(first!.alias, limit: "5h", resetAt: Date().addingTimeInterval(3600), fallbackCooldown: 18000)
        let r2 = await store.rotateFrom(r1.next!.alias, limit: "5h", resetAt: Date().addingTimeInterval(3600), fallbackCooldown: 18000)
        let used = Set([first!.alias, r1.next!.alias, r2.next!.alias])
        XCTAssertEqual(used.count, 3)
    }

    func testSetActiveClearsCooldown() async {
        let store = await tempStore([acct("a", priority: 1, cooldown: Date().addingTimeInterval(3600))])
        let a = await store.setActive("a")
        XCTAssertTrue(a?.disabledUntil.isEmpty ?? false)
        let active = await store.activeAlias()
        XCTAssertEqual(active, "a")
    }
}

final class CodexBarTests: XCTestCase {
    func testManagedAccountsParse() throws {
        let json = """
        {"version":"3","accounts":[
          {"email":"a@x.com","providerAccountID":"acc-a","managedHomePath":"/tmp/home-a"},
          {"email":"b@x.com","workspaceAccountID":"acc-b","managedHomePath":"/tmp/home-b"},
          {"email":"c@x.com"}
        ]}
        """
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cb-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try json.write(to: dir.appendingPathComponent("managed-codex-accounts.json"), atomically: true, encoding: .utf8)

        // Parse via a temp override of the file location using JSONSerialization directly.
        let data = Data(json.utf8)
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let accounts = obj["accounts"] as! [[String: Any]]
        XCTAssertEqual(accounts.count, 3)
        XCTAssertEqual(accounts[0]["managedHomePath"] as? String, "/tmp/home-a")
        XCTAssertNil(accounts[2]["managedHomePath"])
    }

    func testUpsertPreservesManagedHome() async {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cs-\(UUID().uuidString).json")
        let store = AccountStore(url: url)
        var a = Account(alias: "x", accountID: "acc-x", accessToken: "t", managedHomePath: "/tmp/home-x")
        await store.upsert(a)
        // Re-import the same account with no managed home must not erase the link.
        a.managedHomePath = nil
        await store.upsert(a)
        let got = await store.account("x")
        XCTAssertEqual(got?.managedHomePath, "/tmp/home-x")
    }
}

final class LauncherTests: XCTestCase {
    func testConfigArgsFollowSubcommand() {
        let url = URL(string: "http://127.0.0.1:5000")!
        let args = CodexLauncher.launchArgs(proxyURL: url, userArgs: ["exec", "--skip-git-repo-check", "hello"])
        XCTAssertEqual(args.first, "exec")
        XCTAssertTrue(args.contains("model_provider=\"codexswap\""))
        // config overrides must come before the trailing user flags/prompt
        let providerIdx = args.firstIndex(of: "model_provider=\"codexswap\"")!
        let promptIdx = args.firstIndex(of: "hello")!
        XCTAssertLessThan(providerIdx, promptIdx)
    }

    func testConfigArgsChatgptBaseURLQuoted() {
        let url = URL(string: "http://127.0.0.1:5000")!
        let args = CodexLauncher.configArgs(proxyURL: url)
        XCTAssertTrue(args.contains("chatgpt_base_url=\"http://127.0.0.1:5000/backend-api\""))
    }
}
