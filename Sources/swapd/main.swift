import Foundation
import SwapKit

func loadSettings() -> Settings {
    guard let data = try? Data(contentsOf: AppPaths.settingsFile()),
          let s = try? JSONDecoder().decode(Settings.self, from: data) else { return .default }
    return s
}

func fmtCooldown(_ d: Date?) -> String {
    guard let d else { return "-" }
    let f = DateFormatter(); f.dateFormat = "MMM d HH:mm"
    return f.string(from: d)
}

let args = Array(CommandLine.arguments.dropFirst())
let command = args.first ?? "help"

let store = AccountStore(url: AppPaths.storeFile(), strategy: loadSettings().rotationStrategy)
let settingsStore = SettingsStore(url: AppPaths.settingsFile())
// Reconcile local pause deadlines before commands that may perform account work.
// A usage-limit dry-run is read-only and therefore skips this write path.
if SwapdBootstrap.shouldArchiveDueAccounts(arguments: args) {
    _ = await store.archiveDueAccounts()
}

@Sendable func settingsProvider() async -> Settings { loadSettings() }
let verboseEnabled = ProcessInfo.processInfo.environment["CODEXSWAP_VERBOSE"] != nil

switch command {
case "agent":
    let cli = AgentCLI(
        store: store,
        settingsStore: settingsStore,
        supportDir: AppPaths.supportDir(),
        runtimeURLProvider: RuntimeHandoff.readProxyURL
    )
    let result = await cli.run(args)
    FileHandle.standardOutput.write(result.encoded)
    FileHandle.standardOutput.write(Data("\n".utf8))
    exit(Int32(result.exitCode))

case "import":
    let importer = AccountImporter.self
    var added = 0
    for acc in importer.codexBarAccounts() {
        await store.upsert(acc)
        print("imported CodexBar-managed account: \(acc.alias) <\(acc.email)> plan=\(acc.planType ?? "?")")
        added += 1
    }
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
    let accounts = await store.activeAccounts()
    let active = await store.activeAlias()
    if accounts.isEmpty { print("no accounts. run: swapd import"); break }
    let ranked = accounts.sorted(by: { $0.priority > $1.priority })
    for (rank, a) in ranked.enumerated() {
        let mark = a.alias == active ? "*" : " "
        let cooldown = a.cooldownUntil(now: Date()).map { " limited→\(fmtCooldown($0))" } ?? ""
        let needs = a.needsLogin ? " NEEDS-LOGIN" : ""
        let usage = a.usage.map { "\($0.label):\($0.usedPercent)%" }.joined(separator: " ")
        print("\(mark) [rank #\(rank + 1)/\(ranked.count)] \(a.alias)  <\(a.email)>  \(usage)\(cooldown)\(needs)")
    }

case "usage":
    let client = UsageClient()
    for a in await store.activeAccounts() where !a.accessToken.isEmpty {
        do {
            let windows = try await client.fetch(accessToken: a.accessToken, accountID: a.accountID)
            await store.updateUsage(a.alias, windows: windows)
            let formatter = UsageResetPresentation()
            let u = windows.map { "\($0.label):\($0.usedPercent)% \(formatter.cliCaption(for: $0))" }.joined(separator: "  ")
            print("\(a.alias): \(u)")
        } catch {
            print("\(a.alias): usage error \(error)")
        }
    }

case "quota":
    guard args.count == 2, args[1] == "--json" else {
        FileHandle.standardError.write(Data("usage: swapd quota --json\n".utf8))
        exit(64)
    }

    do {
        let service = QuotaReportService(usageService: UsageClient(), resetService: QuotaResetClient())
        let accounts = await store.activeAccounts()
        let hasArchivedAccounts = !(await store.archivedAccounts()).isEmpty
        let prefetched: [String: PrefetchedQuotaSnapshot] = hasArchivedAccounts
            ? [:]
            : ((try? await CodexBarQuotaClient().fetch(accounts: accounts)) ?? [:])
        let activeAlias = await store.activeAlias()
        let report = try await service.fetch(accounts: accounts, activeAlias: activeAlias, prefetched: prefetched)
        let encoded = try QuotaReportJSON.encode(report)
        FileHandle.standardOutput.write(encoded)
        FileHandle.standardOutput.write(Data("\n".utf8))
    } catch is CancellationError {
        FileHandle.standardError.write(Data("quota request cancelled\n".utf8))
        exit(130)
    } catch {
        FileHandle.standardError.write(Data("quota request failed\n".utf8))
        exit(1)
    }

case "warmup":
    guard args.count == 3, args[1] == "--all", args[2] == "--json" else {
        FileHandle.standardError.write(Data("usage: swapd warmup --all --json\n".utf8))
        exit(64)
    }

    let report = await HeadlessWarmup.runFromRuntimeHandoff(
        store: store,
        settings: loadSettings()
    )
    do {
        let encoded = try HeadlessWarmupReportJSON.encode(report)
        FileHandle.standardOutput.write(encoded)
        FileHandle.standardOutput.write(Data("\n".utf8))
    } catch {
        FileHandle.standardError.write(Data("warmup report failed\n".utf8))
        exit(1)
    }

case "priority":
    guard args.count >= 3, let p = Int(args[2]) else { print("usage: swapd priority <alias> <int>"); break }
    guard await store.account(args[1]) != nil else { print("no such account: \(args[1])"); exit(1) }
    await store.setPriority(args[1], priority: p)
    print("set \(args[1]) priority=\(p)")

case "switch":
    guard args.count >= 2 else { print("usage: swapd switch <alias>"); break }
    if let a = await store.setActive(args[1]) { print("active: \(a.alias)") } else { print("no such account: \(args[1])"); exit(1) }

case "shim":
    print(RuntimeHandoff.shimScript())

case "proxy":
    let proxy = FreshAlternativeResolver.makeProxy(
        store: store,
        settingsProvider: settingsProvider,
        verbose: verboseEnabled
    )
    try await proxy.start()
    guard let url = await proxy.proxyURL() else { print("failed to bind"); exit(1) }
    print("proxy listening at \(url)")
    print("codex args:", CodexLauncher.configArgs(proxyURL: url).joined(separator: " "))
    try await Task.sleep(nanoseconds: .max)

case "run":
    guard let codexBin = CodexLauncher.resolveCodexBinary() else { print("codex binary not found"); exit(1) }
    let proxy = FreshAlternativeResolver.makeProxy(
        store: store,
        settingsProvider: settingsProvider,
        verbose: verboseEnabled
    )
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

case "help", "--help", "-h":
    printHelp()

default:
    FileHandle.standardError.write("unknown command: \(command)\n".data(using: .utf8)!)
    printHelp()
    exit(1)
}

func printHelp() {
    print("""
    swapd — CodexSwap headless proxy + account tool
      import           auto-detect and import codex accounts
      list             list accounts, priority, usage, cooldowns
      usage            poll wham/usage for each account
      quota --json     fresh read-only usage/reset-credit status for every account
      warmup --all --json  force a safe all-account quota warm-up through the running app proxy
      agent ...         machine-readable, sanitized control namespace (run `swapd agent --help`)
      priority <a> <n> set account priority (higher consumed first)
      switch <a>       set active account
      shim             print the codexswap shim script
      proxy            run the proxy only (prints URL + codex args)
      run [args...]    start proxy and launch codex through it
      help             show this help
    """)
}
