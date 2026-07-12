import Foundation

public enum CodexLauncher {
    public static let providerName = "codexswap"

    /// The `-c` overrides that route Codex's ChatGPT + Codex traffic through our proxy.
    /// Codex still attaches its own auth; the proxy overwrites it with the active account's token.
    public static func configArgs(proxyURL: URL) -> [String] {
        let base = proxyURL.absoluteString.trimmingTrailingSlash()
        let chatgptBase = "\(base)/backend-api"
        let codexBase = "\(chatgptBase)/codex"
        return [
            "-c", "chatgpt_base_url=\"\(chatgptBase)\"",
            "-c", "model_providers.\(providerName)={ name=\"CodexSwap\", base_url=\"\(codexBase)\", wire_api=\"responses\", requires_openai_auth=true }",
            "-c", "model_provider=\"\(providerName)\"",
        ]
    }

    public static func launchArgs(proxyURL: URL, userArgs: [String]) -> [String] {
        let config = configArgs(proxyURL: proxyURL)
        // Codex honors these overrides only when they follow the subcommand token
        // (e.g. `codex exec -c ...`), so splice them in right after it.
        if let first = userArgs.first, !first.hasPrefix("-") {
            return [first] + config + Array(userArgs.dropFirst())
        }
        return config + userArgs
    }

    public static func warmupArgs(proxyURL: URL, alias: String) -> [String] {
        let base = proxyURL.absoluteString.trimmingTrailingSlash() + "/backend-api/codex"
        let provider = "model_providers.codexswap-warmup={ name=\"CodexSwap Warm-up\", base_url=\"\(tomlEscape(base))\", wire_api=\"responses\", env_key=\"CODEXSWAP_WARMUP_TOKEN\", http_headers={ \"\(ProxyRequestMode.warmupHeader)\"=\"\(tomlEscape(alias))\" } }"
        return [
            "exec",
            "--ephemeral",
            "--skip-git-repo-check",
            "--ignore-rules",
            "--sandbox", "read-only",
            "-c", "approval_policy=\"never\"",
            "-c", provider,
            "-c", "model_provider=\"codexswap-warmup\"",
            "Reply exactly OK. Do not use tools.",
        ]
    }

    public static func resolveCodexBinary() -> String? {
        if let custom = ProcessInfo.processInfo.environment["CODEXSWAP_CODEX_BIN"], !custom.isEmpty { return custom }
        let candidates = [
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/codex").path,
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
        ]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) { return c }
        return nil
    }

    public static func resolveWarmupBinary() -> String? {
        if let custom = ProcessInfo.processInfo.environment["CODEXSWAP_CODEX_BIN"], !custom.isEmpty { return custom }
        let candidates = [
            "/opt/homebrew/bin/codex",
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/usr/local/bin/codex",
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/codex").path,
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func tomlEscape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}

extension String {
    func trimmingTrailingSlash() -> String {
        hasSuffix("/") ? String(dropLast()) : self
    }
}
