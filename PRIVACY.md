# Privacy

CodexSwap is a local macOS utility. It does not operate a CodexSwap cloud service, collect analytics, or send telemetry.

## Data stored locally

CodexSwap stores its settings, account rotation state, quota observations, and warm-up ledger below:

`~/Library/Application Support/CodexSwap/`

Account entries can contain OpenAI access and refresh tokens. Files created by CodexSwap use user-only permissions where supported. CodexSwap can also read credentials from the active Codex home and from CodexBar-managed Codex homes when the user has configured those applications.

## Network activity

CodexSwap listens only on the IPv4 loopback interface. Requests sent through the proxy are forwarded to the corresponding OpenAI or ChatGPT Codex service. Usage refreshes and optional quota warm-up requests also contact OpenAI services.

CodexSwap does not send account information to the project maintainer or to an independent CodexSwap endpoint.

## Account ownership

CodexBar-managed accounts remain owned by CodexBar. CodexSwap reads the managed roster and token files needed for routing but does not register new accounts by editing CodexBar's private roster.

Standalone accounts are imported from Codex authentication files the user creates through `codex login`.

## Deletion

Removing CodexSwap's application-support directory deletes CodexSwap settings and imported state. It does not delete `~/.codex`, CodexBar-managed homes, or OpenAI account data.

Uninstalling the application does not revoke OpenAI sessions. Use Codex, CodexBar, or OpenAI account controls to sign out or revoke credentials.
