import Foundation
import SwapKit

func loadSettings() -> Settings {
    guard let data = try? Data(contentsOf: AppPaths.settingsFile()),
          let s = try? JSONDecoder().decode(Settings.self, from: data) else { return .default }
    return s
}

func saveSettings(_ s: Settings) {
    try? FileManager.default.createDirectory(at: AppPaths.supportDir(), withIntermediateDirectories: true)
    if let data = try? JSONEncoder().encode(s) { try? data.write(to: AppPaths.settingsFile()) }
}

func fmtReset(_ d: Date?) -> String {
    guard let d else { return "-" }
    let f = DateFormatter(); f.dateFormat = "MMM d HH:mm"
    return f.string(from: d)
}

let args = Array(CommandLine.arguments.dropFirst())
let command = args.first ?? "help"

let store = AccountStore(url: AppPaths.storeFile(), strategy: loadSettings().rotationStrategy)

@Sendable func settingsProvider() async -> Settings { loadSettings() }
let verboseEnabled = ProcessInfo.processInfo.environment["CODEXSWAP_VERBOSE"] != nil

switch command {
case "import":
    let importer = AccountImporter.self
    var added = 0
    if let current = importer.currentCodexAccount() {
        await store.upsert(current)
        print("imported active codex login: \(current.alias) <\(current.email)> plan=\(current.planType ?? "?")")
        added += 1
    }
    for acc in importer.existingCodexAuthAccounts() {
        await store.upsert(acc)
        print("imported existing account: \(acc.alias) <\(acc.email)>")
        added += 1
    }
    print("done, \(added) account(s) processed. total: \(await store.all().count)")

case "list":
    let accounts = await store.all()
    let active = await store.activeAlias()
    if accounts.isEmpty { print("no accounts. run: swapd import"); break }
    for a in accounts.sorted(by: { $0.priority > $1.priority }) {
        let mark = a.alias == active ? "*" : " "
        let cooldown = a.cooldownUntil(now: Date()).map { " limited→\(fmtReset($0))" } ?? ""
        let needs = a.needsLogin ? " NEEDS-LOGIN" : ""
        let usage = a.usage.map { "\($0.label):\($0.usedPercent)%" }.joined(separator: " ")
        print("\(mark) [p\(a.priority)] \(a.alias)  <\(a.email)>  \(usage)\(cooldown)\(needs)")
    }

case "usage":
    let client = UsageClient()
    for a in await store.all() where !a.accessToken.isEmpty {
        do {
            let windows = try await client.fetch(accessToken: a.accessToken, accountID: a.accountID)
            await store.updateUsage(a.alias, windows: windows)
            let u = windows.map { "\($0.label):\($0.usedPercent)% reset \(fmtReset($0.resetAt))" }.joined(separator: "  ")
            print("\(a.alias): \(u)")
        } catch {
            print("\(a.alias): usage error \(error)")
        }
    }

case "priority":
    guard args.count >= 3, let p = Int(args[2]) else { print("usage: swapd priority <alias> <int>"); break }
    await store.setPriority(args[1], priority: p)
    print("set \(args[1]) priority=\(p)")

case "switch":
    guard args.count >= 2 else { print("usage: swapd switch <alias>"); break }
    if let a = await store.setActive(args[1]) { print("active: \(a.alias)") } else { print("no such account") }

case "proxy":
    var cfg = ProxyServer.Config()
    let proxy = ProxyServer(store: store, settingsProvider: settingsProvider, verbose: verboseEnabled)
    try await proxy.start()
    guard let url = await proxy.proxyURL() else { print("failed to bind"); exit(1) }
    print("proxy listening at \(url)")
    print("codex args:", CodexLauncher.configArgs(proxyURL: url).joined(separator: " "))
    _ = cfg
    try await Task.sleep(nanoseconds: .max)

case "run":
    guard let codexBin = CodexLauncher.resolveCodexBinary() else { print("codex binary not found"); exit(1) }
    let proxy = ProxyServer(store: store, settingsProvider: settingsProvider, verbose: verboseEnabled)
    try await proxy.start()
    guard let url = await proxy.proxyURL() else { print("failed to bind proxy"); exit(1) }
    FileHandle.standardError.write("CodexSwap proxy at \(url)\n".data(using: .utf8)!)

    let userArgs = Array(args.dropFirst())
    let process = Process()
    process.executableURL = URL(fileURLWithPath: codexBin)
    process.arguments = CodexLauncher.launchArgs(proxyURL: url, userArgs: userArgs)
    process.environment = ProcessInfo.processInfo.environment
    if ProcessInfo.processInfo.environment["CODEXSWAP_NULL_STDIN"] != nil {
        process.standardInput = FileHandle.nullDevice
    }

    let status: Int32 = await withCheckedContinuation { (cont: CheckedContinuation<Int32, Never>) in
        process.terminationHandler = { p in cont.resume(returning: p.terminationStatus) }
        do { try process.run() } catch {
            FileHandle.standardError.write("failed to launch codex: \(error)\n".data(using: .utf8)!)
            cont.resume(returning: 127)
        }
    }
    await proxy.stop()
    exit(status)

default:
    print("""
    swapd — CodexSwap headless proxy + account tool
      import           auto-detect and import codex accounts
      list             list accounts, priority, usage, cooldowns
      usage            poll wham/usage for each account
      priority <a> <n> set account priority (higher consumed first)
      switch <a>       set active account
      proxy            run the proxy only (prints URL + codex args)
      run [args...]    start proxy and launch codex through it
    """)
}
