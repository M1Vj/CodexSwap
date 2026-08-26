# Privacy

CodexSwap is a local macOS utility. It does not operate a CodexSwap cloud service, collect analytics, or send telemetry.

## Data stored locally

CodexSwap stores its settings, account rotation state, quota observations, and warm-up ledger below:

`~/Library/Application Support/CodexSwap/`

Account entries can contain OpenAI access and refresh tokens. Files created by CodexSwap use user-only permissions where supported. CodexSwap can also read credentials from the active Codex home and from CodexBar-managed Codex homes when the user has configured those applications.

## Network activity

CodexSwap listens only on the IPv4 loopback interface. Requests sent through the proxy are forwarded to the corresponding OpenAI or ChatGPT Codex service. Usage refreshes and optional quota warm-up requests also contact OpenAI services.

CodexSwap does not send account information to the project maintainer or to an independent CodexSwap endpoint.

### Optional Alpha review delegation

When Codex or another configured MCP client invokes the review tool, the invoking client sends the bounded task content it includes, including any file contents the invoking client includes in that task, over the network to a third-party remote Alpha provider. The server cannot enforce a separate human confirmation at invocation time. The Alpha worker runs in a private task directory with workspace file tools denied, so it cannot inspect the live workspace. In the intended Codex workflow, GPT-5.6 Sol remains the parent/orchestrator; another configured MCP client may invoke the tool without Sol as its parent. Alpha's response returns as untrusted evidence to the invoking client. Manual registration remains explicit: a global `codexswap_alpha` MCP registration may affect future or new Codex sessions, so verify that the reserved name is unused before setup. CodexSwap does not automatically add or remove this registration.

## Account ownership

CodexBar-managed accounts remain owned by CodexBar. CodexSwap reads the managed roster and token files needed for routing but does not register new accounts by editing CodexBar's private roster.

Standalone accounts are imported from Codex authentication files the user creates through `codex login`.

## Deletion

Removing CodexSwap's application-support directory deletes CodexSwap settings and imported state. It does not delete `~/.codex`, CodexBar-managed homes, or OpenAI account data.

Uninstalling the application does not revoke OpenAI sessions. Use Codex, CodexBar, or OpenAI account controls to sign out or revoke credentials.
