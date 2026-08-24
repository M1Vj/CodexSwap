# Provider-linked subagent rosters

## Decision

CodexSwap stores one native subagent roster for each supported parent-provider family:

- OpenAI parents use the owner's normal role-aware roster: GPT-5.6 Luna at max for ordinary roles and GPT-5.6 Sol at high for `sol_adversarial`, unless the owner customizes that OpenAI profile.
- Bridged Alpha parents use 0x Alpha for every installed native subagent role, with the saved Alpha effort and Alpha Ultra preference.

The profiles remain independent. Editing or applying the Alpha profile must not overwrite the OpenAI profile, and returning to an OpenAI parent must not require rebuilding the previous GPT roster by hand.

Native Codex delegation stays provider-homogeneous. GPT-parent to Alpha-child `spawn_agent` remains blocked because the cross-provider encrypted task can be empty. The separately registered, attachment-only `codexswap_alpha_review` MCP remains the supported Sol-to-Alpha review path and is outside this profile switch.

## Data model and migration

`Settings.subagentModelPolicy` keeps its existing JSON key but changes from one `SubagentModelPolicy` to a provider-linked profile container. The container owns:

- `openAI`: one `SubagentModelPolicy`.
- `bridged`: one `SubagentModelPolicy`.

The container's decoder accepts both the new profile shape and the legacy single-policy shape. Legacy migration is deterministic:

1. If every saved role assignment uses Alpha, preserve that roster as the bridged profile and seed the OpenAI profile from the normal Luna/Sol defaults.
2. Otherwise, preserve non-Alpha role assignments and eligible models as the OpenAI profile.
3. Seed the bridged profile by assigning every saved role identity to Alpha. Use `ultra` when the legacy Alpha Ultra flag is enabled and `max` otherwise.
4. Remove cross-provider eligible IDs from each migrated profile so the two profiles begin provider-homogeneous.
5. Malformed, missing, or unknown profile data falls back to safe defaults. Unknown parent families never select a profile.

Encoding writes only the new `{ openAI, bridged }` representation. No credentials, account identifiers, session data, or model-provider secrets enter this settings object.

## Runtime selection

### Task Board

Task Board already creates an isolated Codex home and knows the task's parent model before launch. The materializer resolves that model against the exact staged catalog, determines its provider family, selects the matching profile, validates it, and writes only that profile's installed role assignments.

Selection is fail-closed:

- Missing, duplicated, malformed, or unknown parent models stage nothing.
- A selected profile with mixed provider families, missing roles, unsupported effort, or unknown models stages nothing.
- The source Codex home remains read-only, and the existing transactional rollback and safe-projection rules remain in force.

### Interactive Codex sessions

Codex role files are global and static after a session starts. CodexSwap cannot truthfully switch those files for one request or one already-running session based on a model observed later at the proxy.

The Advanced settings screen therefore resolves the parent declared by the current Codex configuration, loads that family's saved profile, and applies only that profile after the owner presses Apply. The screen tells the owner that new Codex sessions see the applied roster. Refreshing after the configured parent changes loads the other saved profile without discarding either draft.

CodexSwap does not run a background watcher that rewrites global role files. This avoids racing active sessions or changing unrelated sessions without an explicit Apply action.

## UI behavior

The Subagent Models section shows one short provider-profile label near the existing parent compatibility information:

- `Editing OpenAI parent profile`
- `Editing Alpha parent profile`

The helper copy explains:

- Task Board selects the matching profile before launch.
- Interactive Codex uses the profile applied to global role files and needs a new session after changes.
- Cross-provider native rosters remain unavailable.

The existing model controls, per-role effort controls, Alpha Ultra toggle, bulk assignment, warnings, error states, and `Restore compatible defaults` action stay in place. Restore operates only on the visible provider profile. Controls remain keyboard accessible and keep their current accessibility identifiers unless a new label needs its own identifier.

## Security boundary

Trust boundaries:

- Model catalog entries, settings JSON, role files, and configured parent IDs are untrusted local input.
- Global role files affect future Codex sessions and must change only after explicit Apply.
- Task Board targets are isolated task-owned homes; they must never receive credentials, history, plugins, skills, or unrelated instructions.
- Alpha MCP output remains untrusted external text. Profile selection does not grant it workspace tools or native child status.

Abuse cases and controls:

- A tampered settings file mixes GPT and Alpha roles: validation blocks Apply and Task Board materialization.
- A parent ID is missing or duplicated in the catalog: selection fails closed and writes nothing.
- A legacy settings file contains Alpha as merely eligible while GPT roles are assigned: migration keeps the GPT assignments in the OpenAI profile and creates an all-Alpha bridged profile.
- A user changes the global parent while Codex sessions are running: CodexSwap does not rewrite role files until explicit Apply, and the UI requires a new session.
- A future provider family appears: no profile is selected until CodexSwap adds an explicit supported-family mapping.

## Observable contract

```gherkin
Feature: Provider-linked native subagent rosters

  Rule: Task Board chooses a roster from the parent known before launch

    Scenario: An Alpha Task Board run starts
      Given the saved bridged profile assigns Alpha to every installed role
      And the task parent resolves uniquely to the bridged provider
      When CodexSwap materializes the task Codex home
      Then every installed native role uses Alpha with the saved Alpha effort
      And the OpenAI profile remains unchanged

    Scenario: A GPT Task Board run starts after an Alpha run
      Given the saved OpenAI profile uses Luna for ordinary roles and Sol for the adversarial role
      And the task parent resolves uniquely to OpenAI
      When CodexSwap materializes the task Codex home
      Then the installed native roles use the saved OpenAI profile
      And no Alpha assignment is staged

  Rule: Existing settings migrate without losing the owner's intent

    Scenario: Legacy settings contain the normal GPT roster and Alpha Ultra is enabled
      Given the settings contain one legacy subagent policy
      When CodexSwap decodes the settings
      Then the OpenAI profile preserves the GPT role assignments
      And the bridged profile assigns Alpha Ultra to every saved role

  Rule: Interactive role changes remain explicit

    Scenario: The configured parent changes from Alpha to GPT
      Given both provider profiles are saved
      When the owner refreshes the Subagent Models section
      Then CodexSwap displays the OpenAI profile
      And neither global role files nor the Alpha profile change until Apply is pressed
      And the UI explains that a new Codex session is required

  Rule: Unknown provider state never mutates role files

    Scenario: The configured parent is missing from the catalog
      When the owner refreshes or applies the profile
      Then CodexSwap reports a bounded actionable error
      And no role, catalog, parent, or settings file is changed
```

## Non-goals

- Switching native role files during an already-running interactive Codex session.
- Enabling GPT-parent to Alpha-child native `spawn_agent`.
- Replacing the attachment-only Alpha MCP or giving it workspace access.
- Automatically changing the Codex parent model.
- Adding a generic unlimited provider-profile map before another supported provider family exists.
- Reworking cache accounting, Alpha runner containment, account routing, or unrelated Advanced settings UI.

## Verification gates

- RED to GREEN migration and round-trip tests for legacy GPT, legacy Alpha, malformed, and new profile settings.
- RED to GREEN Task Board materialization tests for OpenAI selection, Alpha selection, sequential parent changes, and unknown-parent no-write behavior.
- Focused presentation and settings tests for provider-profile loading, isolated persistence, restore behavior, bounded errors, and restart copy.
- Full Swift test suite, release tools, signed app build, `git diff --check`, and deep code-sign verification.
- Packaged Alpha MCP protocol, attachment-only confidentiality, cancellation, and registration identity probes remain green.
- Fresh independent correctness and security reviews inspect one frozen final diff before installation.
- The installed app is replaced only after all gates pass, then reopened immediately and verified on its listener.
