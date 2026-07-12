import Foundation

/// The running app publishes its live proxy URL here so the `codexswap` shim can route Codex through it.
public enum RuntimeHandoff {
    public static func proxyURLFile() -> URL {
        AppPaths.supportDir().appendingPathComponent("proxy.url")
    }

    public static func writeProxyURL(_ url: URL) {
        try? FileManager.default.createDirectory(at: AppPaths.supportDir(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? url.absoluteString.write(to: proxyURLFile(), atomically: true, encoding: .utf8)
    }

    public static func clearProxyURL() {
        try? FileManager.default.removeItem(at: proxyURLFile())
    }

    public static func readProxyURL() -> URL? {
        guard let s = try? String(contentsOf: proxyURLFile(), encoding: .utf8) else { return nil }
        return URL(string: s.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The shell shim users put on PATH as `codexswap` (or alias `codex` to). It routes Codex through
    /// the app's running proxy, splicing config overrides after the subcommand token.
    public static func shimScript() -> String {
        """
        #!/usr/bin/env bash
        # codexswap — routes the Codex CLI through the running CodexSwap proxy.
        set -euo pipefail
        URL_FILE="$HOME/Library/Application Support/CodexSwap/proxy.url"
        REAL_CODEX="${CODEXSWAP_CODEX_BIN:-}"
        if [ -z "$REAL_CODEX" ]; then
          for c in "$HOME/.local/bin/codex" /opt/homebrew/bin/codex /usr/local/bin/codex; do
            [ -x "$c" ] && REAL_CODEX="$c" && break
          done
        fi
        [ -x "$REAL_CODEX" ] || { echo "codexswap: codex binary not found" >&2; exit 127; }
        if [ ! -f "$URL_FILE" ]; then
          echo "codexswap: CodexSwap app not running (no proxy). Launch it first." >&2
          exec "$REAL_CODEX" "$@"
        fi
        URL="$(cat "$URL_FILE")"
        BASE="$URL/backend-api"
        CODEXBASE="$BASE/codex"
        PROVIDER='model_providers.codexswap={ name="CodexSwap", base_url="'"$CODEXBASE"'", wire_api="responses", requires_openai_auth=true }'
        CFG=(-c "chatgpt_base_url=\\"$BASE\\"" -c "$PROVIDER" -c 'model_provider="codexswap"')
        if [ "$#" -gt 0 ] && [ "${1#-}" = "$1" ]; then
          SUB="$1"; shift
          exec "$REAL_CODEX" "$SUB" "${CFG[@]}" "$@"
        fi
        exec "$REAL_CODEX" "${CFG[@]}" "$@"
        """
    }
}
