# Repeated sign-outs: credential ownership investigation

Investigated September 6, 2026; upstream findings updated September 8. This is a source-grounded diagnosis, not proof that every reported sign-out has the same cause.

## Finding

At the investigated baseline, CodexSwap's refresh path violated the ownership contract of the credentials it imported. It independently redeemed an imported refresh token and wrote the replacement into a CodexBar-managed home. The protective correction described below removes that behavior. CodexBar's current implementation intentionally avoids doing that: native Codex owns refresh and persistence, and usage readers treat shared credentials as read-only.

The local proxy's in-flight refresh map only coordinates requests inside that proxy actor. It does not coordinate Codex, CodexBar's native recovery process, another `swapd` process, or another proxy. An atomic file replacement does not make the preceding OAuth request and subsequent write an atomic operation across these writers.

This is a concrete source defect and a credible mechanism for recurring stale-session failures. No real credential was refreshed or revoked to reproduce it. The exact writer sequence behind the owner's historical incidents remains unverified.

## September 8 upstream follow-up

Several distinct failures can produce a sign-in warning. Keep their evidence separate:

- **Explicit revocation:** a provider response containing `token_revoked` establishes that the presented credential was rejected as revoked. It does not identify the revoking client or prove that another native home has no usable credentials for the same account.
- **Pre-login revocation:** Codex 0.153.4 calls `clear_existing_auth_before_login`, which invokes `logout_with_revoke`, before starting ChatGPT login. Issue #22577 reports effects on other sessions. The source verifies the revoke call, but the report does not establish its scope for every account. CodexSwap's corrected standalone launcher uses a fresh private home, file-based storage, and a one-attempt guard rather than logging into an already populated home.
- **Stale managed credentials:** CodexBar PR #3379 proposes renewal through the credential-owning app-server inside the selected `CODEX_HOME`, followed by a scoped retry. As of September 8 it remains open, with provider-auth sign-off and real denied-workspace evidence outstanding. Its passing fixture tests and pre-rebase live recovery are not a shipped fix.
- **Permission denial:** CodexBar v0.56.8, published September 7, preserves HTTP 403 instead of treating it as expired credentials and starting Auto recovery. This is a shipped classification fix, not proof of a `token_revoked` HTTP 401 remedy. Selected-workspace ownership fixes already shipped in v0.56.4.
- **Upstream desktop loops:** Codex issues #39803 and #40395 report desktop sign-in loss while other clients can remain usable. Issue #39696 reports a Windows Stable/Advanced Account Security interaction. These are reported reproductions, not evidence that the same trigger explains this Mac's incidents.

The contributor response in #10332 remains important: refresh tokens allow reuse within a limited grace window, approximately an hour. Two simultaneous refresh calls do not necessarily invalidate each other immediately. Long-lived stale copies and competing credential owners remain plausible, but concurrency alone is not a complete diagnosis.

For new standalone onboarding, prefer CodexSwap's fresh-home flow. Do not migrate existing accounts merely to test a logout theory, copy auth files, disable account security, redirect revocation endpoints, or repeatedly log out and back in. A browser success page must be followed by successful completion of the original CLI and a verified import. A cached menu label is not a fresh credential-validity check.

The latest stable Codex release checked, 0.153.4, lists model-picker and guidance changes rather than an authentication repair. No general upgrade cure was established. The separate warm-up PATH correction fixes a subprocess launch failure; it does not restore revoked credentials.

Issue #42581 reports successful fresh device-code login followed immediately by
`token_revoked` on both MCP startup and a core request, reproduced on CLI 0.152.1
and 0.153.0. This is a close symptom match outside CodexSwap, not proof of the same
cause or of a shipped fix. Another reporter explicitly retracted a competing-client
diagnosis in #31459 after isolating a desktop account-settings request and comparing
desktop builds. That correction is a reason to avoid attributing every sign-out to
refresh races. Neither report establishes the cause of a particular local incident.

Additional primary sources checked September 8:

- Contributor clarification: `https://github.com/openai/codex/issues/10332#issuecomment-3831635259`
- Login/logout propagation report: `https://github.com/openai/codex/issues/22577`
- Current login source: `https://github.com/openai/codex/blob/rust-v0.153.4/codex-rs/cli/src/login.rs`
- Pending selected-home renewal: `https://github.com/steipete/CodexBar/pull/3379`
- Shipped permission classification: `https://github.com/steipete/CodexBar/releases/tag/v0.56.8`
- Desktop/CLI disagreement: `https://github.com/openai/codex/issues/39803`
- Desktop token loss: `https://github.com/openai/codex/issues/40395`
- Security-mode reproduction: `https://github.com/openai/codex/issues/39696`
- CLI release: `https://github.com/openai/codex/releases/tag/rust-v0.153.4`
- Fresh-login revocation report: `https://github.com/openai/codex/issues/42581`
- Retracted competing-client diagnosis: `https://github.com/openai/codex/issues/31459#issuecomment-5353509721`

## September 12 CodexBar 0.59 workspace and standalone renewal repair

The installed CodexBar is 0.59.0 build 142. Its current managed-account model
defines `workspaceAccountID` as the explicitly selected remote workspace and
uses `providerAccountID` only as a legacy fallback. The source also states that
the managed auth file may name a different default workspace. CodexSwap had the
precedence reversed and rejected a managed credential unless the token's
default workspace equaled the selected workspace. That combination could omit
the freshly logged-in CodexBar record while leaving an older CodexSwap record,
usage reading, or credential source visible under the same account label.

The correction keeps two identities separate: `accountID` is the workspace sent
in `ChatGPT-Account-Id`, while `credentialAccountID` is the OAuth bundle owner
used to detect a swapped or mismatched auth file. CodexBar roster reconciliation,
read-through hydration, verified recovery, persistence, and conditional
quarantine now retain both identities. A selected workspace can differ from the
token's default workspace without weakening the credential-owner check. When a
roster entry migrates from a retired workspace identity, CodexSwap preserves
user-owned routing controls but clears workspace-scoped usage, cooldown, and
history state and keeps the account blocked until a fresh verified quota read.

Standalone login had a separate lifecycle defect. `ProxyServer` accepted a
`TokenRefresher` but discarded it, so a CodexSwap-owned standalone account could
never renew after its first access token expired. The repair enables refresh
only for a verified CodexSwap standalone home: private owned directories, UUID
home, success marker, exact source path, matching credential identity, and the
cross-process standalone-home lock are required. Rotated access, refresh, and ID
tokens are atomically written back to that same owned auth document while
preserving unknown fields, then committed to the account store. CodexBar,
ambient native Codex, and legacy sources remain read-only. A 401 gets one owned
refresh and one retry; a second 401 is quarantined instead of looping.

The official Codex source is the authority for the refresh request. Its current
`RefreshRequest` sends `client_id`, `grant_type`, and `refresh_token`, without a
`scope` field, and persists returned rotated tokens plus `last_refresh`. CodexBar's
generic helper includes `scope`, but its active native strategy deliberately
defers shared credential renewal to the owning Codex process. CodexSwap therefore
uses the official request shape and applies it only to its exclusively owned
standalone homes.

The privacy-safe live snapshot for `alyy2` on September 12 did not report a
sign-out: `needsLogin` was false. It reported a 100% weekly window and a cooldown
through the recorded reset, so the current installed build considered that
record quota-ineligible. That snapshot does not prove the reading belongs to the
same CodexBar-selected workspace; the reversed workspace precedence is the
confirmed local defect that could make those states diverge. No live credential
or raw account identifier was inspected during this diagnosis.

Focused synthetic coverage verifies selected-workspace precedence, distinct
credential identity, mismatch rejection, managed rotation, standalone-only
ownership, unknown-field preservation, one refresh across concurrent callers,
rotated-token persistence, invalid-grant classification, and a successful
401-refresh-retry sequence. These tests do not prove that every provider-side
`token_revoked` incident is local: upstream issues #40918, #41171, and #42581
document similar first-interaction failures outside CodexSwap.

### Observable scenarios

```gherkin
Scenario: CodexBar selects a workspace different from the token default
  Given a valid managed OAuth bundle for its default workspace
  And the CodexBar roster selects another workspace
  When CodexSwap reconciles and routes the account
  Then it sends the selected workspace header
  And it still validates rotations against the credential owner
```

Passed with synthetic roster, hydration, recovery, and migration tests.

```gherkin
Scenario: A CodexSwap-owned standalone access token is rejected
  Given a verified private standalone home
  When the first upstream request returns 401
  Then CodexSwap persists one rotated refresh bundle under the shared lock
  And retries the original request once
  And a second 401 ends without another refresh loop
```

The refresh and successful retry paths passed synthetic tests. The second-401
quarantine is covered by the existing bounded retry behavior; no live account
was intentionally forced to reject a refreshed credential.

```gherkin
Scenario: A CodexBar or ambient native credential needs renewal
  Given the credential source is not a verified CodexSwap standalone home
  When CodexSwap sees expiry or 401
  Then it does not redeem or write that source's refresh token
```

Passed with external-source ownership and proxy no-refresh regressions.

```gherkin
Scenario: The reported alyy2 login is reconciled after installation
  Given the current installed build reports authenticated but quota-ineligible state
  When the repaired build starts and performs a fresh managed-workspace sync
  Then obsolete identity state is migrated without an alias suffix
  And a fresh quota read determines routing eligibility
```

Not tested against the live account before installation. Installation validation
must use only the sanitized agent status and quota surfaces.

Primary sources checked September 12:

- CodexBar managed workspace semantics: `https://github.com/steipete/CodexBar/blob/8b254dbec11ddd5c5547878d9640e4e965306c71/Sources/CodexBarCore/CodexManagedAccounts.swift`
- CodexBar workspace header use: `https://github.com/steipete/CodexBar/blob/8b254dbec11ddd5c5547878d9640e4e965306c71/Sources/CodexBarCore/Providers/Codex/CodexOAuth/CodexOAuthUsageFetcher.swift`
- CodexBar refresh helper and error mapping: `https://github.com/steipete/CodexBar/blob/8b254dbec11ddd5c5547878d9640e4e965306c71/Sources/CodexBarCore/Providers/Codex/CodexOAuth/CodexTokenRefresher.swift`
- Official Codex refresh request and persistence: `https://github.com/openai/codex/blob/aee8a55ab6010f1d53e741edec74dbcffa07bcfe/codex-rs/login/src/auth/manager.rs`
- Official Codex auth storage model: `https://github.com/openai/codex/blob/aee8a55ab6010f1d53e741edec74dbcffa07bcfe/codex-rs/login/src/auth/storage.rs`
- Fresh-login immediate revocation report: `https://github.com/openai/codex/issues/42581`
- First-message sign-out report: `https://github.com/openai/codex/issues/40918`
- First-interaction refresh invalidation report: `https://github.com/openai/codex/issues/41171`

## Stale-response quarantine guard

A deterministic local fixture reproduced a separate race: after the proxy checked
for an owner-provided replacement, another writer installed newer credentials
before the old request's 401 handler marked the account as needing sign-in.
The newer credentials were incorrectly quarantined. This does not explain who
revoked the credential used by the old request.

Quarantine now compares the rejected credential snapshot with the persisted
account under the store lock. A stale rejection cannot invalidate a newer
generation. The proxy can retry a changed, eligible access token for the same
account within its existing request budget, without sending a stale sign-in
notification. A revocation of the current credential still fails closed. No
OAuth refresh, provider revocation, or external credential-file write is added.

## September 6 version snapshot and historical timeline

Versions observed at the September 6 baseline: Codex CLI **0.153.4**, CodexBar **0.56.4 build 135**, and CodexSwap **0.2.0 build 4**. These are historical observations, not the current installed versions. Version metadata does not establish that an installed binary is byte-identical to upstream. The September 8 follow-up does not re-verify the restricted PR/commit sources listed in the original timeline; its conclusions use the additional sources above.

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

## Follow-up regression audit (September 6, 2026)

Synthetic tests reproduced additional local defects: a copied Terminal login command could reuse its home; recovery could commit a candidate after its owner file changed during the usage check; a re-added managed account could retain an obsolete home; and expiry alone could clear a sign-in block without validating access. The fixes make login commands single-use, recheck the source at the locked recovery commit, accept identity-checked home replacement only through managed-roster reconciliation, and retain sign-in blocks until explicit read-only usage verification succeeds. Managed imports also reject roster/token identity mismatches. None of these paths renews OAuth tokens or writes external auth files.

The source recheck detects changes observed before commit; it cannot lock out an independent external writer after that read. Recovery is deliberately limited to explicit Rescan/import, not startup, background polling, failover, or warm-up. After completing login with the credential owner, use Rescan to verify access; restarting CodexSwap alone does not clear a sign-in block. Duplicate roster entries for the same account still require an explicit owner-selection policy. Standalone renewal remains outside this fix, and installation alone does not recover a revoked session.

Full-suite validation also reproduced an Alpha MCP startup shutdown race: changing a caught signal to ignored could discard pending shutdown before dispatch-source registration. The handler now remains installed and the startup latch is checked after cancellation is bound. Existing immediate-SIGTERM stress and protocol tests cover this path.

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
