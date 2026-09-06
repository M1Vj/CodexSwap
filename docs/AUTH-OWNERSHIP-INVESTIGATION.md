# Repeated sign-outs: credential ownership investigation

Investigated September 6, 2026. This is a source-grounded diagnosis, not proof that every reported sign-out has the same cause.

## Finding

CodexSwap's refresh path violates the ownership contract of the credentials it imports. It independently redeems an imported refresh token and writes the replacement into a CodexBar-managed home. CodexBar's current implementation intentionally avoids doing that: native Codex owns refresh and persistence, and usage readers treat shared credentials as read-only.

The local proxy's in-flight refresh map only coordinates requests inside that proxy actor. It does not coordinate Codex, CodexBar's native recovery process, another `swapd` process, or another proxy. An atomic file replacement does not make the preceding OAuth request and subsequent write an atomic operation across these writers.

This is a concrete source defect and a credible mechanism for recurring stale-session failures. No real credential was refreshed or revoked to reproduce it. The exact writer sequence behind the owner's historical incidents remains unverified.

## Version and timeline evidence

Locally observed versions: Codex CLI **0.153.4**, CodexBar **0.56.4 build 135**, and CodexSwap **0.2.0 build 4**. Version metadata does not establish that an installed binary is byte-identical to upstream.

| Date | Evidence | Significance |
| --- | --- | --- |
| February 1, 2026 | OpenAI maintainer comment in Codex issue #10332 | Refresh tokens have a limited reuse window, described approximately as an hour. Do not describe all refresh tokens as strictly single-use. |
| February 18, 2026 | Codex PR #11802 merged | Guarded reload/account-mismatch handling improved; this is not an interprocess locking guarantee. |
| March 30, 2026 | CodexBar multi-account commit `dd200dac317d7d018a78449c9245a792a21fae52` | Managed homes are upstream functionality, not merely an obsolete fork. |
| July 12, 2026 | Local CodexSwap commit `2a8b97c` | Managed-home read-through/write-back was introduced. This establishes the age of the code, not the date of a proven incident. |
| August 16, 2026 | CodexBar commit `a29973fe9933c95b4d8073709d858604144e2a8b`, release v0.50.1 | Shared native auth becomes read-only during usage refresh; native recovery owns renewal. PR #2944 documents the rationale but was closed without being merged. |
| August 28, 2026 | CodexBar v0.56.0, following PR #3222 | Native JWT expiry semantics corrected without restoring third-party refresh ownership. |
| September 3, 2026 | CodexBar v0.56.4 | Installed version includes the read-only ownership contract. |

## Why the first recovery patch was insufficient

Reading a newer managed token before refresh or after a 401 can recover an already-resolved stale snapshot. It cannot stop a second process from redeeming the same refresh-token lineage between the read and write. A retry budget limits requests; it does not establish credential ownership.

Neither a CodexSwap-only file lock nor launching another native `codex app-server` proves safety. In the inspected Codex 0.153.4 source, `AuthManager` uses a process-local semaphore. The file storage backend opens `auth.json` with truncate/write/flush and exposes no interprocess compare-and-swap contract. Multiple native processes can still overlap. Codex PR #8645 proposed cross-instance recovery but was closed unmerged; it must not be cited as a shipped fix.

## Source boundaries that must be preserved

- CodexBar-managed homes belong to the native account lifecycle selected by CodexBar. CodexSwap may read them, not rotate or overwrite them.
- Native `CODEX_HOME/auth.json` is also externally owned. A missing `managedHomePath` does not establish ownership by CodexSwap.
- Legacy per-account bundles are snapshots, not proof that CodexSwap is their exclusive writer. Missing provenance must not grant refresh authority.
- The account selected for routing must not silently adopt another account when a shared native home changes login. Workspace identity requires the same care; an unscoped native fallback can target the wrong workspace.
- JWT expiry is not a credential-generation counter. Equal expiry alone does not prove that a different token is newer; a later expiry alone does not prove matching account identity.
- A generic 401 or unavailable renewal source does not prove that the owner must sign in again. Renewal unavailable must be distinguished from confirmed session invalidation.

## Protective correction and rollout boundary

The local correction should make imported credentials read-only, retain known source provenance for read-through, reject mismatched identity, and never send imported or unknown refresh tokens to OAuth from the proxy. When no usable owner update exists, return a renewal-required failure or use an eligible alternative under the existing mode and lease rules. Do not mark an account signed out merely because the proxy is not its refresh owner.

The `ProxyServer` initializer retains its `refresher` argument for source compatibility, but the proxy no longer uses it. Injecting a refresher does not grant authority to renew an imported session.

This protective boundary is **not an automatic renewal implementation**. Expired accounts may remain unavailable until their existing owner renews them. A seamless renewal design requires a proven, exclusively owned authentication lifecycle, including workspace scoping; copying the same rotating session into a new directory is not isolation. Do not silently install this availability tradeoff as a claim that the months-long problem is completely fixed.

Already-revoked credentials cannot be repaired by code alone. They may require one explicit sign-in through their owner after competing writers are eliminated. Repeated automatic login, forced refresh, account deletion, and credential copying are not troubleshooting steps.

Independent review also identified a pre-existing concurrent-import limitation: two writers simultaneously adding different identities under the same alias can cause the store merge to retain only one addition. This change handles ordinary single-writer alias collisions, but does not redesign concurrent alias allocation. Rescan imports serially; this report does not claim that race is fixed.

## Verification and evidence limits

Synthetic regressions must test zero proxy OAuth requests, unchanged external source bytes, two proxy instances sharing one source, owner-update recovery, identity mismatch, and normal/task/warm-up isolation. All stubs and state must be local and disposable.

An earlier test fixture used the default sanitized routing-log destination. Some recent log statuses therefore overlap synthetic tests and cannot be treated as production sign-out counts. Preserve the existing log; isolate new tests rather than deleting or rewriting evidence.

The running installed app was not stopped or replaced during this investigation. Before any authorized replacement, arrange a relaunch independently of the proxy-dependent session and verify the new process, listener, and health endpoint.

## Primary sources

Public GitHub source and release evidence was retrieved directly and through the developer index. Web-search calls supplied no usable citations and later returned an explicit unavailable error; those failed calls are not evidence. No alternate retry was used for the explicitly denied fetches.

- CodexBar v0.56.4 OAuth contract: `https://github.com/steipete/CodexBar/blob/v0.56.4/docs/codex-oauth.md`
- CodexBar v0.56.4 managed-account/workspace behavior: `https://github.com/steipete/CodexBar/blob/v0.56.4/docs/codex.md`
- CodexBar v0.50.1 release: `https://github.com/steipete/CodexBar/releases/tag/v0.50.1`
- CodexBar shared-writer rationale: `https://github.com/steipete/CodexBar/pull/2944`
- CodexBar expiry correction: `https://github.com/steipete/CodexBar/pull/3222`
- Codex 0.153.4 refresh semaphore and reload outcomes: `https://github.com/openai/codex/blob/rust-v0.153.4/codex-rs/login/src/auth/manager.rs` (inspected regions 2033–2051 and 2764–2859)
- Codex 0.153.4 file persistence: `https://github.com/openai/codex/blob/rust-v0.153.4/codex-rs/login/src/auth/storage.rs` (inspected region 154–223)
- Codex app-server managed/external auth semantics: `https://github.com/openai/codex/blob/rust-v0.153.4/codex-rs/app-server/README.md`
- Codex guarded-reload correction: `https://github.com/openai/codex/pull/11802`
- Codex unmerged cross-instance proposal: `https://github.com/openai/codex/pull/8645`
- OpenAI maintainer's limited-reuse-window statement: `https://github.com/openai/codex/issues/10332#issuecomment-3831635259`

The local code references are `Sources/SwapKit/ProxyServer.swift`, `AccountImporter.swift`, `AccountStore.swift`, `CodexBarBridge.swift`, and `CodexAuth.swift`. The baseline examined was `f287e8082fc4d5e26f39429165a23a2c988b5751`, with the uncommitted selection/affinity/recovery candidate layered on top.
