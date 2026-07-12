import AppKit
import UserNotifications
import ServiceManagement
import SwapKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let engine = AppEngine(settingsStore: SettingsStoreBridge.shared)
    private var hasBundle: Bool { Bundle.main.bundleIdentifier != nil }
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var latest = EngineSnapshot(accounts: [], activeAlias: nil, proxyURL: nil, strategy: .priority)
    private var settings = Settings.default

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath.circle", accessibilityDescription: "CodexSwap")
            button.image?.isTemplate = true
        }
        menu.delegate = self
        statusItem.menu = menu
        rebuildMenu()

        if hasBundle {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }

        engine.setEventHandler { [weak self] event in
            Task { @MainActor in self?.handle(event: event) }
        }

        Task { @MainActor in
            do { try await engine.start() } catch {
                self.notify(title: "CodexSwap", body: "Failed to start proxy: \(error.localizedDescription)")
            }
            if self.latest.accounts.isEmpty { await self.engine.importAccounts() }
            await self.refreshSnapshot()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        let sem = DispatchSemaphore(value: 0)
        Task { await engine.stop(); sem.signal() }
        _ = sem.wait(timeout: .now() + 2)
    }

    // MARK: - Snapshot / events

    private func refreshSnapshot() async {
        latest = await engine.snapshot()
        settings = await SettingsStoreBridge.current()
        rebuildMenu()
    }

    private func handle(event: AppEvent) {
        switch event {
        case let .rotated(from, to, limit, resetAt):
            if settings.notifyOnRotate {
                let when = resetAt.map { " (resets \(Self.shortTime($0)))" } ?? ""
                notify(title: "Switched account", body: "\(from) hit \(limit) limit → now using \(to)\(when)")
            }
        case let .exhausted(limit):
            if settings.notifyOnExhausted {
                notify(title: "All accounts limited", body: "Every account is out on \(limit). Codex will error until one resets.")
            }
        case let .needsLogin(alias):
            notify(title: "Account needs sign-in", body: "\(alias) was signed out. Re-add it via Add account…")
        case let .windowReset(alias):
            if settings.notifyOnWindowReset {
                notify(title: "Quota reset", body: "\(alias) is back in rotation.")
            }
        case .refreshed, .snapshotChanged:
            break
        }
        Task { @MainActor in await self.refreshSnapshot() }
    }

    // MARK: - Menu

    private func rebuildMenu() {
        updateStatusIcon()
        menu.removeAllItems()

        // Status line: is the proxy on, and is codex traffic actually flowing through it?
        let statusTitle: String
        if let port = latest.proxyURL?.port {
            if latest.servedCount == 0 {
                statusTitle = "● On — proxy :\(port) · waiting for codex"
            } else if let last = latest.lastActivityAt, Date().timeIntervalSince(last) < 90 {
                statusTitle = "● Working — routing \(latest.lastActivityAlias ?? "?") · \(Self.ago(last))"
            } else {
                statusTitle = "● On — proxy :\(port) · idle (\(latest.servedCount) served)"
            }
        } else {
            statusTitle = "○ Off — proxy not running"
        }
        let status = NSMenuItem(title: statusTitle, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)

        let active = NSMenuItem(title: "Active account: \(latest.activeAlias ?? "none")", action: nil, keyEquivalent: "")
        active.isEnabled = false
        menu.addItem(active)

        if latest.proxyURL != nil && latest.servedCount == 0 {
            let hint = NSMenuItem(title: "Run `codexswap` in your terminal to route codex here", action: nil, keyEquivalent: "")
            hint.isEnabled = false
            menu.addItem(hint)
        }
        menu.addItem(.separator())

        if latest.accounts.isEmpty {
            let empty = NSMenuItem(title: "No accounts — Import accounts below", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else if latest.strategy == .priority && latest.accounts.count > 1 {
            let hint = NSMenuItem(title: "Accounts (higher priority used first ↓)", action: nil, keyEquivalent: "")
            hint.isEnabled = false
            menu.addItem(hint)
        }

        for acc in latest.accounts.sorted(by: { $0.priority > $1.priority }) {
            let item = NSMenuItem(title: label(for: acc), action: #selector(switchAccount(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = acc.alias
            item.state = acc.alias == latest.activeAlias ? .on : .off
            item.submenu = accountSubmenu(acc)
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let stratHeader = NSMenuItem(title: "Rotation strategy", action: nil, keyEquivalent: ""); stratHeader.isEnabled = false
        menu.addItem(stratHeader)
        menu.addItem(strategyItem("Priority (drain highest first)", .priority))
        menu.addItem(strategyItem("Round-robin (balance evenly)", .roundRobin))
        menu.addItem(.separator())

        addAction("Refresh usage now", #selector(refreshUsage))
        addAction("Import accounts", #selector(importAccounts))
        addAction("Add account (codex login)…", #selector(addAccount))
        addAction("Install `codexswap` shim…", #selector(installShim))
        menu.addItem(automaticRoutingItem())
        if latest.routingState == .enabled && !settings.launchAtLogin {
            let warning = NSMenuItem(title: "⚠ Routing requires CodexSwap to be running", action: nil, keyEquivalent: "")
            warning.isEnabled = false
            menu.addItem(warning)
        }
        menu.addItem(notifyToggles())
        menu.addItem(launchAtLoginItem())
        menu.addItem(.separator())
        addAction("Quit CodexSwap", #selector(quit))
    }

    private func label(for acc: Account) -> String {
        var parts = ["priority \(acc.priority) · \(acc.alias)"]
        let u = acc.usage.map { "\($0.label) \($0.usedPercent)%" }.joined(separator: " · ")
        if !u.isEmpty { parts.append(u) }
        if let cd = acc.cooldownUntil(now: Date()) { parts.append("limited→\(Self.shortTime(cd))") }
        if acc.needsLogin { parts.append("NEEDS-LOGIN") }
        return parts.joined(separator: "  ")
    }

    private func accountSubmenu(_ acc: Account) -> NSMenu {
        let sub = NSMenu()
        let sw = NSMenuItem(title: "Switch to \(acc.alias)", action: #selector(switchAccount(_:)), keyEquivalent: "")
        sw.target = self; sw.representedObject = acc.alias
        sub.addItem(sw)
        sub.addItem(.separator())
        let pHeader = NSMenuItem(title: "Set priority (higher = used first)", action: nil, keyEquivalent: ""); pHeader.isEnabled = false
        sub.addItem(pHeader)
        let levels: [(Int, String)] = [(10, "10 — highest"), (5, "5 — high"), (2, "2"), (1, "1"), (0, "0 — lowest")]
        for (p, title) in levels {
            let pi = NSMenuItem(title: "  \(title)", action: #selector(setPriority(_:)), keyEquivalent: "")
            pi.target = self
            pi.representedObject = PriorityChange(alias: acc.alias, priority: p)
            pi.state = acc.priority == p ? .on : .off
            sub.addItem(pi)
        }
        sub.addItem(.separator())
        let rm = NSMenuItem(title: "Remove \(acc.alias)", action: #selector(removeAccount(_:)), keyEquivalent: "")
        rm.target = self; rm.representedObject = acc.alias
        sub.addItem(rm)
        return sub
    }

    private func strategyItem(_ title: String, _ strategy: RotationStrategy) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(setStrategy(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = strategy.rawValue
        item.state = latest.strategy == strategy ? .on : .off
        return item
    }

    private func notifyToggles() -> NSMenuItem {
        let parent = NSMenuItem(title: "Notifications", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.addItem(toggle("On auto-switch", settings.notifyOnRotate, #selector(toggleNotifyRotate)))
        sub.addItem(toggle("On all exhausted", settings.notifyOnExhausted, #selector(toggleNotifyExhausted)))
        sub.addItem(toggle("On quota reset", settings.notifyOnWindowReset, #selector(toggleNotifyReset)))
        parent.submenu = sub
        return parent
    }

    private func launchAtLoginItem() -> NSMenuItem {
        let item = toggle("Launch at login", settings.launchAtLogin, #selector(toggleLaunchAtLogin))
        return item
    }

    private func automaticRoutingItem() -> NSMenuItem {
        switch latest.routingState {
        case .disabled:
            return toggle("Route Codex through CodexSwap", false, #selector(toggleAutomaticRouting))
        case .enabled:
            return toggle("Route Codex through CodexSwap", true, #selector(toggleAutomaticRouting))
        case .needsRepair:
            let item = NSMenuItem(title: "Repair Codex routing…", action: #selector(toggleAutomaticRouting), keyEquivalent: "")
            item.target = self
            return item
        }
    }

    private func toggle(_ title: String, _ on: Bool, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.state = on ? .on : .off
        return item
    }

    private func addAction(_ title: String, _ action: Selector) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    // MARK: - Actions

    @objc private func switchAccount(_ sender: NSMenuItem) {
        guard let alias = sender.representedObject as? String else { return }
        Task { await engine.switchTo(alias); await refreshSnapshot() }
    }

    @objc private func setPriority(_ sender: NSMenuItem) {
        guard let change = sender.representedObject as? PriorityChange else { return }
        Task { await engine.setPriority(change.alias, priority: change.priority); await refreshSnapshot() }
    }

    @objc private func removeAccount(_ sender: NSMenuItem) {
        guard let alias = sender.representedObject as? String else { return }
        Task { await engine.remove(alias); await refreshSnapshot() }
    }

    @objc private func setStrategy(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let s = RotationStrategy(rawValue: raw) else { return }
        Task { await engine.setStrategy(s); await refreshSnapshot() }
    }

    @objc private func refreshUsage() { Task { await engine.refreshAllUsage(); await refreshSnapshot() } }
    @objc private func importAccounts() { Task { await engine.importAccounts(); await refreshSnapshot() } }

    @objc private func addAccount() {
        guard let codex = CodexLauncher.resolveCodexBinary() else {
            notify(title: "CodexSwap", body: "codex binary not found on PATH.")
            return
        }
        let script = "tell application \"Terminal\" to do script \"\(codex) login\""
        runAppleScript(script)
        notify(title: "CodexSwap", body: "Complete login in Terminal, then choose Import accounts.")
    }

    @objc private func installShim() {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("codexswap")
        do {
            try RuntimeHandoff.shimScript().write(to: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
            notify(title: "CodexSwap", body: "Installed shim at ~/.local/bin/codexswap. Run `codexswap` instead of `codex`.")
        } catch {
            notify(title: "CodexSwap", body: "Failed to install shim: \(error.localizedDescription)")
        }
    }

    @objc private func toggleNotifyRotate() { updateSettings { $0.notifyOnRotate.toggle() } }
    @objc private func toggleNotifyExhausted() { updateSettings { $0.notifyOnExhausted.toggle() } }
    @objc private func toggleNotifyReset() { updateSettings { $0.notifyOnWindowReset.toggle() } }

    @objc private func toggleAutomaticRouting() {
        Task { @MainActor in
            do {
                switch latest.routingState {
                case .enabled:
                    try await engine.setAutomaticRouting(false)
                    notify(title: "CodexSwap routing disabled", body: "Your previous Codex provider settings were restored.")
                case .disabled:
                    await enableLaunchAtLoginForRouting()
                    try await engine.setAutomaticRouting(true)
                    notify(title: "CodexSwap routing enabled", body: "Restart existing Codex sessions to apply automatic account routing.")
                case .needsRepair:
                    try await engine.repairAutomaticRouting()
                    notify(title: "CodexSwap routing repaired", body: "Restart existing Codex sessions to apply the repaired configuration.")
                }
            } catch {
                notify(title: "CodexSwap routing unchanged", body: error.localizedDescription)
            }
            await refreshSnapshot()
        }
    }

    private func enableLaunchAtLoginForRouting() async {
        guard !settings.launchAtLogin else { return }
        guard hasBundle else {
            notify(title: "Launch at login unavailable", body: "Install and open the packaged CodexSwap.app to enable launch at login.")
            return
        }
        do {
            try SMAppService.mainApp.register()
            settings = await SettingsStoreBridge.update { $0.launchAtLogin = true }
        } catch {
            notify(title: "Launch at login unchanged", body: error.localizedDescription)
        }
    }

    @objc private func toggleLaunchAtLogin() {
        let newValue = !settings.launchAtLogin
        guard hasBundle else {
            notify(title: "CodexSwap", body: "Launch-at-login needs the packaged .app (not the dev binary).")
            return
        }
        do {
            if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            updateSettings { $0.launchAtLogin = newValue }
        } catch {
            notify(title: "CodexSwap", body: "Launch-at-login change failed: \(error.localizedDescription)")
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }

    private func updateSettings(_ mutate: @escaping @Sendable (inout Settings) -> Void) {
        Task {
            settings = await SettingsStoreBridge.update(mutate)
            await refreshSnapshot()
        }
    }

    // MARK: - Helpers

    private func notify(title: String, body: String) {
        guard hasBundle else {
            FileHandle.standardError.write("[notify] \(title): \(body)\n".data(using: .utf8)!)
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    private func runAppleScript(_ source: String) {
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
    }

    static func shortTime(_ date: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "MMM d HH:mm"; return f.string(from: date)
    }

    static func ago(_ date: Date) -> String {
        let s = Int(Date().timeIntervalSince(date))
        if s < 5 { return "just now" }
        if s < 60 { return "\(s)s ago" }
        if s < 3600 { return "\(s / 60)m ago" }
        return "\(s / 3600)h ago"
    }

    private func updateStatusIcon() {
        guard let button = statusItem.button else { return }
        let working = latest.isRunning && latest.lastActivityAt.map { Date().timeIntervalSince($0) < 90 } == true
        let name = latest.isRunning ? "arrow.triangle.2.circlepath.circle.fill" : "arrow.triangle.2.circlepath.circle"
        button.image = NSImage(systemSymbolName: name, accessibilityDescription: "CodexSwap")
        button.image?.isTemplate = !working
        button.contentTintColor = working ? .systemGreen : nil
    }

    private struct PriorityChange { let alias: String; let priority: Int }
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        Task { @MainActor in await refreshSnapshot() }
    }
}

/// The SettingsStore is an actor; the menu needs its value synchronously-ish, so bridge through a shared instance.
enum SettingsStoreBridge {
    static let shared = SettingsStore()
    static func current() async -> Settings { await shared.get() }
    static func update(_ mutate: @escaping @Sendable (inout Settings) -> Void) async -> Settings { await shared.update(mutate) }
}
