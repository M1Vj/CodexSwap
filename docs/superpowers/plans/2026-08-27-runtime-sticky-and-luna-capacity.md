# Runtime sticky accounts and Luna capacity routing plan

## Goal

Implement the approved runtime-only sticky menu lock, latched Smart Switch
draining preference, and bounded model-aware Luna opportunity routing while
preserving hard account safety and `max` reasoning.

## Work items

1. **AccountStore runtime state and tests**
   - Add non-persisted sticky alias, draining hold alias, and Luna rejection
     state.
   - Centralize hard-routable checks; make `current` honor sticky/draining holds
     before percentage ordering and lease avoidance.
   - Clear holds on semantic limits and hard invalidation; add an atomic Luna
     opportunity reservation that can bypass only cooldown.
   - Add actor tests for toggle, restart non-persistence, 100% usage, draining
     hold, and Luna cooldown selection.

2. **Proxy selection and failover**
   - Parse the normalized request model before selection.
   - Pass model context into normal reservation and use the Luna opportunity
     path only for `gpt-5.6-luna`.
   - Record Luna cooldown rejections on semantic 429 and avoid retrying that
     account in the same request; keep existing non-quota 429 behavior.
   - Remove percentage-only rejection from fresh alternatives while retaining
     hard eligibility and atomic reservation semantics.
   - Add focused proxy/helper tests for Luna selection and quota failover.

3. **Menu UI and AppEngine snapshot**
   - Expose sticky alias/toggle through `EngineSnapshot` and `AppEngine`.
   - Add a lock badge, accessibility summary, help text, and double-click gesture
     to `MenuAccountRow`/`MenuRowContainer` while preserving single-click select.
   - Show a concise sticky status line in the menu.
   - Add SwiftUI/container tests where supported and verify build-time API usage.

4. **Verification and delivery**
   - Run focused Swift tests, then the full package test/build checks required by
     the repository.
   - Inspect the complete diff and ensure unrelated `.task-*` artifacts remain
     unstaged.
   - Rebuild/install CodexSwap, verify the installed version and menu behavior,
     commit with scoped paths, and push to the verified private origin.

## Acceptance mapping

| Requirement | Evidence |
| --- | --- |
| Double-click toggles runtime sticky | Menu/container test + actor test |
| Sticky ignores 100% and polling churn | AccountStore tests |
| Quota 429 clears and fails over | Proxy/actor tests |
| Non-quota 429 stays sticky | Proxy test |
| Draining account is held until error | AccountStore tests |
| Luna can probe cooling account safely | Proxy/actor tests |
| Luna remains max reasoning | Existing role config + model policy test |
| No sticky persistence | restart/init test |
| Push complete change | scoped commit + `git ls-remote` |
