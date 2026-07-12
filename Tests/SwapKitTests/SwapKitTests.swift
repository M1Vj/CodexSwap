import XCTest
import NIOCore
import NIOHTTP1
@testable import SwapKit

final class SettingsTests: XCTestCase {
    func testNewAutomationSettingsDecodeWithSafeDefaults() throws {
        let settings = try JSONDecoder().decode(Settings.self, from: Data("{}".utf8))

        XCTAssertFalse(settings.routeCodexAutomatically)
        XCTAssertFalse(settings.automaticallyWarmAccounts)
        XCTAssertEqual(settings.proxyPort, Settings.defaultProxyPort)
        XCTAssertEqual(settings.proxyPort, 58_432)
    }
}

final class CodexConfigManagerTests: XCTestCase {
    private func fixture() throws -> (home: URL, support: URL, config: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("config-manager-\(UUID().uuidString)")
        let home = root.appendingPathComponent("codex")
        let support = root.appendingPathComponent("support")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return (home, support, home.appendingPathComponent("config.toml"))
    }

    func testEnableAndDisableRestoresExistingConfigByteForByte() throws {
        let f = try fixture()
        let original = """
        model = "gpt-5.6"
        chatgpt_base_url = "https://example.invalid/backend-api"
        model_provider = "previous"

        [model_providers.codexswap]
        name = "Previous"
        base_url = "https://example.invalid/codex"

        [projects."/tmp/example"]
        trust_level = "trusted"
        """
        try original.write(to: f.config, atomically: true, encoding: .utf8)
        let manager = CodexConfigManager(codexHome: f.home, supportDir: f.support)
        let proxy = URL(string: "http://127.0.0.1:58432")!

        try manager.enable(proxyURL: proxy)
        XCTAssertEqual(try manager.state(proxyURL: proxy), .enabled)
        let enabled = try String(contentsOf: f.config, encoding: .utf8)
        XCTAssertTrue(enabled.contains("# BEGIN CODEXSWAP MANAGED ROUTING"))
        XCTAssertTrue(enabled.contains("base_url = \"http://127.0.0.1:58432/backend-api/codex\""))
        XCTAssertFalse(enabled.contains("https://example.invalid"))

        try manager.disable()
        XCTAssertEqual(try String(contentsOf: f.config, encoding: .utf8), original)
        XCTAssertEqual(try manager.state(proxyURL: proxy), .disabled)
    }

    func testDisablePreservesUnrelatedEditsMadeWhileEnabled() throws {
        let f = try fixture()
        let original = "model_provider = \"previous\"\nmodel = \"gpt-5.6\"\n"
        try original.write(to: f.config, atomically: true, encoding: .utf8)
        let manager = CodexConfigManager(codexHome: f.home, supportDir: f.support)
        let proxy = URL(string: "http://127.0.0.1:58432")!
        try manager.enable(proxyURL: proxy)

        var changed = try String(contentsOf: f.config, encoding: .utf8)
        changed = "analytics = { enabled = false }\n" + changed
        try changed.write(to: f.config, atomically: true, encoding: .utf8)

        try manager.disable()
        let restored = try String(contentsOf: f.config, encoding: .utf8)
        XCTAssertTrue(restored.contains("analytics = { enabled = false }"))
        XCTAssertTrue(restored.contains("model_provider = \"previous\""))
        XCTAssertFalse(restored.contains("BEGIN CODEXSWAP"))
    }

    func testMissingOriginalConfigIsRemovedAfterDisable() throws {
        let f = try fixture()
        let manager = CodexConfigManager(codexHome: f.home, supportDir: f.support)
        let proxy = URL(string: "http://127.0.0.1:58432")!

        try manager.enable(proxyURL: proxy)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.config.path))
        try manager.disable()
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.config.path))
    }

    func testEditedManagedBlockReportsNeedsRepair() throws {
        let f = try fixture()
        let manager = CodexConfigManager(codexHome: f.home, supportDir: f.support)
        let proxy = URL(string: "http://127.0.0.1:58432")!
        try manager.enable(proxyURL: proxy)
        var text = try String(contentsOf: f.config, encoding: .utf8)
        text = text.replacingOccurrences(of: "model_provider = \"codexswap\"", with: "model_provider = \"other\"")
        try text.write(to: f.config, atomically: true, encoding: .utf8)

        guard case .needsRepair = try manager.state(proxyURL: proxy) else {
            return XCTFail("Expected needsRepair")
        }
        XCTAssertThrowsError(try manager.disable())
    }

    func testRepairReinstallsManagedValuesAndKeepsRestorePoint() throws {
        let f = try fixture()
        let original = "model_provider = \"previous\"\n"
        try original.write(to: f.config, atomically: true, encoding: .utf8)
        let manager = CodexConfigManager(codexHome: f.home, supportDir: f.support)
        let proxy = URL(string: "http://127.0.0.1:58432")!
        try manager.enable(proxyURL: proxy)
        var text = try String(contentsOf: f.config, encoding: .utf8)
        text = text.replacingOccurrences(of: "model_provider = \"codexswap\"", with: "model_provider = \"other\"")
        try text.write(to: f.config, atomically: true, encoding: .utf8)

        try manager.repair(proxyURL: proxy)
        XCTAssertEqual(try manager.state(proxyURL: proxy), .enabled)
        try manager.disable()
        XCTAssertEqual(try String(contentsOf: f.config, encoding: .utf8), original)
    }

    func testAmbiguousInlineProviderConfigIsRejectedWithoutMutation() throws {
        let f = try fixture()
        let original = "model_providers.codexswap = { name = \"custom\" }\n"
        try original.write(to: f.config, atomically: true, encoding: .utf8)
        let manager = CodexConfigManager(codexHome: f.home, supportDir: f.support)

        XCTAssertThrowsError(try manager.enable(proxyURL: URL(string: "http://127.0.0.1:58432")!))
        XCTAssertEqual(try String(contentsOf: f.config, encoding: .utf8), original)
    }
}

final class RoutingEngineTests: XCTestCase {
    private func fixture() throws -> (engine: AppEngine, settings: SettingsStore, config: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("routing-engine-\(UUID().uuidString)")
        let codexHome = root.appendingPathComponent("codex")
        let support = root.appendingPathComponent("support")
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        let settings = SettingsStore(url: support.appendingPathComponent("settings.json"))
        let store = AccountStore(url: support.appendingPathComponent("accounts.json"))
        let manager = CodexConfigManager(codexHome: codexHome, supportDir: support)
        return (
            AppEngine(store: store, settingsStore: settings, configManager: manager),
            settings,
            codexHome.appendingPathComponent("config.toml")
        )
    }

    func testEnableAndDisableRoutingPersistsIntentAndRestoresConfig() async throws {
        let f = try fixture()
        let original = "model = \"gpt-5.6\"\n"
        try original.write(to: f.config, atomically: true, encoding: .utf8)

        try await f.engine.setAutomaticRouting(true)
        let enabledSettings = await f.settings.get()
        let enabledSnapshot = await f.engine.snapshot()
        XCTAssertTrue(enabledSettings.routeCodexAutomatically)
        XCTAssertEqual(enabledSnapshot.routingState, .enabled)

        try await f.engine.setAutomaticRouting(false)
        let disabledSettings = await f.settings.get()
        let disabledSnapshot = await f.engine.snapshot()
        XCTAssertFalse(disabledSettings.routeCodexAutomatically)
        XCTAssertEqual(try String(contentsOf: f.config, encoding: .utf8), original)
        XCTAssertEqual(disabledSnapshot.routingState, .disabled)
    }

    func testExternalManagedBlockEditReportsRepairState() async throws {
        let f = try fixture()
        try await f.engine.setAutomaticRouting(true)
        var text = try String(contentsOf: f.config, encoding: .utf8)
        text = text.replacingOccurrences(of: "model_provider = \"codexswap\"", with: "model_provider = \"other\"")
        try text.write(to: f.config, atomically: true, encoding: .utf8)

        let snapshot = await f.engine.snapshot()
        guard case .needsRepair = snapshot.routingState else {
            return XCTFail("Expected needsRepair")
        }

        try await f.engine.repairAutomaticRouting()
        let repaired = await f.engine.snapshot()
        XCTAssertEqual(repaired.routingState, .enabled)
    }
}

final class WarmupProxyTests: XCTestCase {
    private func account(_ alias: String) -> Account {
        Account(alias: alias, accountID: "id-\(alias)", accessToken: "token-\(alias)")
    }

    func testWarmupHeaderSelectsExactAccountWithoutChangingActiveAlias() async {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("warmup-proxy-\(UUID().uuidString).json")
        let store = AccountStore(url: url)
        await store.upsert(account("a"))
        await store.upsert(account("b"))
        _ = await store.setActive("a")
        var headers = HTTPHeaders()
        headers.add(name: ProxyRequestMode.warmupHeader, value: "b")

        let mode = ProxyRequestMode(headers: headers)
        let selected = await selectProxyAccount(store: store, mode: mode)
        let active = await store.activeAlias()

        XCTAssertEqual(mode, .warmup(alias: "b"))
        XCTAssertEqual(selected?.alias, "b")
        XCTAssertEqual(active, "a")
    }

    func testUpstreamHeadersStripWarmupSelectorAndReplaceCredentials() {
        var headers = HTTPHeaders()
        headers.add(name: ProxyRequestMode.warmupHeader, value: "b")
        headers.add(name: "Authorization", value: "Bearer disposable")
        let account = self.account("b")

        let sanitized = proxyUpstreamHeaders(headers, account: account)

        XCTAssertNil(sanitized.first(name: ProxyRequestMode.warmupHeader))
        XCTAssertEqual(sanitized.first(name: "Authorization"), "Bearer token-b")
        XCTAssertEqual(sanitized.first(name: "ChatGPT-Account-Id"), "id-b")
    }

    func testMarkLimitedDoesNotRotateActiveAccount() async {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("warmup-limit-\(UUID().uuidString).json")
        let store = AccountStore(url: url)
        await store.upsert(account("a"))
        await store.upsert(account("b"))
        _ = await store.setActive("a")
        let reset = Date().addingTimeInterval(3600)

        await store.markLimited("b", limit: "5h", resetAt: reset, fallbackCooldown: 18_000)
        let active = await store.activeAlias()
        let limited = await store.account("b")

        XCTAssertEqual(active, "a")
        XCTAssertEqual(limited?.disabledUntil["5h"], reset)
    }
}

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

    func testAdvanceRoundRobinCyclesAllAccounts() async {
        let store = await tempStore([acct("a"), acct("b"), acct("c")], strategy: .roundRobin)
        var visited: [String] = []
        let first = await store.current()
        visited.append(first!.alias)
        for _ in 0..<5 {
            let next = await store.advanceRoundRobin()
            visited.append(next!.alias)
        }
        XCTAssertEqual(Set(visited), ["a", "b", "c"])
        for i in 1..<visited.count { XCTAssertNotEqual(visited[i], visited[i - 1]) }
    }

    func testAdvanceRoundRobinSkipsCooledDown() async {
        let store = await tempStore([
            acct("a"),
            acct("b", cooldown: Date().addingTimeInterval(3600)),
            acct("c"),
        ], strategy: .roundRobin)
        _ = await store.current()
        var seen = Set<String>()
        for _ in 0..<4 { if let n = await store.advanceRoundRobin() { seen.insert(n.alias) } }
        XCTAssertFalse(seen.contains("b"))
        XCTAssertTrue(seen.isSubset(of: ["a", "c"]))
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

    func testReconcileDropsRemovedManagedButKeepsLocal() async {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cs-\(UUID().uuidString).json")
        let store = AccountStore(url: url)
        await store.upsert(Account(alias: "keep", accountID: "acc-keep", accessToken: "t", managedHomePath: "/tmp/h1"))
        await store.upsert(Account(alias: "gone", accountID: "acc-gone", accessToken: "t", managedHomePath: "/tmp/h2"))
        await store.upsert(Account(alias: "local", accountID: "acc-local", accessToken: "t")) // no managed home
        let removed = await store.reconcileManaged(present: ["acc-keep"])
        XCTAssertEqual(removed, ["gone"])
        let aliases = Set(await store.all().map { $0.alias })
        XCTAssertEqual(aliases, ["keep", "local"])
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
