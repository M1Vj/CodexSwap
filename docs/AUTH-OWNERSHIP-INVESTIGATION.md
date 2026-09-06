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

### Direct Terminal login follow-up

After the protective ownership change was installed, the owner reported another sign-out. The owner clarified that the affected account was added through CodexBar; direct CodexSwap login was first tried on September 5, 2026. The long-running sign-out issue therefore cannot be attributed to that recent experiment from timing alone.

Source inspection found an independent onboarding risk: the installed `CodexLoginLauncher` executes unscoped `codex login`, which can replace the default or inherited native credential location. A synthetic invocation of the committed launcher replaced a sentinel native auth file. This is not evidence that it invalidated the affected CodexBar session. The follow-up candidate isolates new logins in fresh homes and imports only completed CLI logins; browser success alone does not establish successful CLI persistence.

The owner subsequently distinguished two cases: the affected account initially still worked through CodexBar/native Codex while CodexSwap retained `needsLogin`, then native Codex also signed out after seconds of use with CodexSwap routing disabled. Some accounts had been signed in through both applications. The second observation means a proxied request is not a necessary trigger for every reported logout. It does not identify the process that originally invalidated the refresh-token lineage, and disabling routing does not roll back an earlier invalidation. A reviewer process also reported an explicit revoked-refresh-token error during this investigation; that process was not independently mapped to the affected account.

At 19:15 Philippine time on September 6, the safe runtime interface reported routing enabled again and the existing build 5 process still listening. This later snapshot does not contradict the owner's disabled-routing observation at the time of the logout. No routing setting was changed by this investigation.

The safe account interface reports a persisted `needsLogin` flag, not the provider error or the time the flag was set. The affected account's opaque reference can be correlated with the privacy-safe routing log without reading credentials: its last retained successful terminal response was at 14:22:26 Philippine time on September 6, before build 5 reopened at 14:24:59. The active log contained no terminal 401 for that reference. This does not exclude an intermediate authentication error, and it does not prove that the owner can still refresh the session.

The strongest historical code-level explanation remains competing refresh ownership: the old proxy redeemed imported refresh tokens, wrote CodexBar's managed home, and treated any refresh-endpoint 401 as invalidation. Native Codex could retain a different generation in memory. A persistent sign-in flag can also outlive the event that set it. Neither explanation is established for this particular report without the exact displaying application's error. The correction prevents the proxy from continuing that refresh/write-back behavior; it cannot undo an already-invalidated provider session.

### Native login explicitly revokes the previous grant

Exact-tag source supplies a stronger explanation for recent mixed-login cases. In Codex `rust-v0.153.4`, `codex-rs/cli/src/login.rs` calls `clear_existing_auth_before_login` before starting browser or device login. That helper invokes `logout_with_revoke`. The login auth manager loads the existing home credentials, attempts OAuth revocation, then clears the local stores. `auth/revoke.rs` prefers the refresh token and sends it to `/oauth/revoke`. Revocation is attempted before the new browser flow completes; abandoning or delaying the new login does not undo it. The callback's `persist_tokens_async` only saves the new bundle and is not the revocation trigger.

CodexBar `v0.56.4` account promotion copies the selected managed account's auth material into the live native home. Promotion itself does not revoke it. If an unscoped native login later starts in that home, Codex can revoke a grant also held in the managed home. Existing access tokens may still appear usable until a later request or renewal exposes the revoked grant; the exact server timing is not established here.

This is a source-confirmed mechanism, not proof of the affected account's actual sequence. The owner reported promotion and mixed login attempts, but no private credential lineage was inspected. It cannot establish the cause of every monthlong incident, nor prove the same native behavior existed in every earlier installed version. New CodexSwap logins now use fresh empty homes and forced file storage, so the native login's preflight has no previous shared account there to revoke. Existing CodexBar/native credentials are neither copied nor migrated by this fix.

### Managed-workspace renewal availability

CodexBar v0.56.4 provides a more directly relevant availability mechanism. `CodexOAuthCredentials.needsRefresh` considers native credentials due for refresh within five minutes of JWT expiry. Its OAuth preparation raises `nativeRefreshRequired` rather than redeeming the shared token itself. However, `CodexOAuthNativeRefreshCLIStrategy.isAvailable` rejects a context with a selected managed workspace. The source explains that the CLI fallback cannot carry the selected workspace header safely; its tests explicitly assert that automatic mode exposes no unscoped CLI fallback for that context.

Consequently, a managed-workspace account can encounter unavailable renewal even though no refresh-token revocation has been demonstrated. CodexBar's credential error guidance can suggest login for missing/unreadable files, required renewal, or an expired/invalid access token. These are not interchangeable diagnoses. The affected account's actual workspace scope and error remain unverified; this is a source-confirmed mechanism, not a proven attribution.

The build 5 proxy correction intentionally does not fill that gap: it stopped acting as a competing refresh owner, but did not supply a workspace-safe native renewal owner. Re-enabling proxy refresh or starting an unscoped app-server would undo the safety boundary. A durable renewal implementation must first establish exact account/workspace ownership and coordinate its lifecycle.

Upstream issue #3143 also demonstrates that keyring-backed native login can remain authenticated while CodexBar's file-based/fallback usage path reports unavailable data. That issue is not proof the affected managed account uses keyring storage. The missing-JWT-expiry fallback bug described in #3221 was fixed by #3222 before v0.56.4 and must not be cited as an unfixed cause on the installed version.

Synthetic regressions must test zero proxy OAuth requests, unchanged external source bytes, two proxy instances sharing one source, owner-update recovery, identity mismatch, and normal/task/warm-up isolation. All stubs and state must be local and disposable.

An earlier test fixture used the default sanitized routing-log destination. Some recent log statuses therefore overlap synthetic tests and cannot be treated as production sign-out counts. Preserve the existing log; isolate new tests rather than deleting or rewriting evidence.

The protective ownership change was installed as local build 5 on September 6, 2026, with an independent automatic relaunch and verified listener/health. Before any further authorized replacement, arrange the same independent relaunch and verify the new process, listener, and health endpoint. Installation is not evidence that an existing invalidated credential has recovered.

## Primary sources

Public GitHub source and release evidence was retrieved directly and through the developer index. Web-search calls supplied no usable citations and later returned an explicit unavailable error; those failed calls are not evidence. No alternate retry was used for the explicitly denied fetches.

- CodexBar v0.56.4 OAuth contract: `https://github.com/steipete/CodexBar/blob/v0.56.4/docs/codex-oauth.md`
- CodexBar v0.56.4 managed-account/workspace behavior: `https://github.com/steipete/CodexBar/blob/v0.56.4/docs/codex.md`
- CodexBar v0.50.1 release: `https://github.com/steipete/CodexBar/releases/tag/v0.50.1`
- CodexBar shared-writer rationale: `https://github.com/steipete/CodexBar/pull/2944`
- CodexBar expiry correction: `https://github.com/steipete/CodexBar/pull/3222`
- CodexBar v0.56.4 native credential expiry and error categories: `https://github.com/steipete/CodexBar/blob/v0.56.4/Sources/CodexBarCore/Providers/Codex/CodexOAuth/CodexOAuthCredentials.swift`
- CodexBar v0.56.4 managed-workspace fallback guard: `https://github.com/steipete/CodexBar/blob/v0.56.4/Sources/CodexBarCore/Providers/Codex/CodexProviderDescriptor.swift`
- CodexBar managed-workspace recovery regression tests: `https://github.com/steipete/CodexBar/blob/v0.56.4/Tests/CodexBarTests/CodexOAuthManagedWorkspaceRecoveryTests.swift`
- CodexBar keyring/file-source availability report (opened August 22, closed August 25, 2026): `https://github.com/steipete/CodexBar/issues/3143`
- Codex 0.153.4 refresh semaphore and reload outcomes: `https://github.com/openai/codex/blob/rust-v0.153.4/codex-rs/login/src/auth/manager.rs` (inspected regions 2033–2051 and 2764–2859)
- Codex 0.153.4 pre-login revocation: `https://github.com/openai/codex/blob/rust-v0.153.4/codex-rs/cli/src/login.rs` (122–168; device flows 318–435)
- Codex 0.153.4 revocation implementation: `https://github.com/openai/codex/blob/rust-v0.153.4/codex-rs/login/src/auth/revoke.rs` (55–85 and 97–153), and `auth/manager.rs` (951–976)
- CodexBar 0.56.4 native account promotion: `https://github.com/steipete/CodexBar/blob/v0.56.4/Sources/CodexBar/CodexAccountPromotionService.swift` (214–263)
- Codex 0.153.4 file persistence: `https://github.com/openai/codex/blob/rust-v0.153.4/codex-rs/login/src/auth/storage.rs` (inspected region 154–223)
- Codex app-server managed/external auth semantics: `https://github.com/openai/codex/blob/rust-v0.153.4/codex-rs/app-server/README.md`
- Codex guarded-reload correction: `https://github.com/openai/codex/pull/11802`
- Codex unmerged cross-instance proposal: `https://github.com/openai/codex/pull/8645`
- OpenAI maintainer's limited-reuse-window statement: `https://github.com/openai/codex/issues/10332#issuecomment-3831635259`

The local code references are `Sources/SwapKit/ProxyServer.swift`, `AccountImporter.swift`, `AccountStore.swift`, `CodexBarBridge.swift`, and `CodexAuth.swift`. The baseline examined was `f287e8082fc4d5e26f39429165a23a2c988b5751`, with the uncommitted selection/affinity/recovery candidate layered on top.
