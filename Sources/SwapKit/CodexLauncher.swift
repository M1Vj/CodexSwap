import Foundation

public enum CodexLauncher {
    /// Route the built-in OpenAI provider's model traffic through the proxy without
    /// changing the provider identity used by Codex history and thread metadata.
    public static func configArgs(proxyURL: URL) -> [String] {
        let base = proxyURL.absoluteString.trimmingTrailingSlash()
        let codexBase = "\(base)/backend-api/codex"
        return [
            "-c", "openai_base_url=\"\(codexBase)\"",
            "-c", "model_provider=\"openai\"",
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
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
    }
}

extension String {
    func trimmingTrailingSlash() -> String {
        hasSuffix("/") ? String(dropLast()) : self
    }
}
