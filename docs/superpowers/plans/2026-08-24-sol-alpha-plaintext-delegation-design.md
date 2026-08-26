# Sol-orchestrated 0x Alpha delegation design

## Decision

CodexSwap keeps GPT-5.6 Sol as the parent and orchestrator for the intended Codex workflow. Native Codex `spawn_agent` remains provider-homogeneous and fail-closed: a GPT parent cannot safely launch a bridged Alpha role because the child task can arrive empty or unreadable before the request reaches CodexSwap. Another configured MCP client may invoke the review tool, but that invocation does not make the client a Sol child or grant it native Codex parent status.

For users who explicitly register it, CodexSwap exposes a separate local MCP review surface. Sol calls an ordinary plaintext tool, CodexSwap launches a bounded OpenCode process using `opencode/x-preview-f-free`, and the result returns as tool output. This is an external worker, not a native Codex child. It has no Codex child thread ID, encrypted session continuity, or implicit parent context. The bounded task, including any file excerpts Sol explicitly embeds, is disclosed to the external Alpha provider.

This design follows the current Codex MCP integration surface and OpenCode's documented non-interactive `run`, model selection, inline configuration, and permission controls:

- https://developers.openai.com/codex/mcp
- https://opencode.ai/docs/cli/
- https://opencode.ai/docs/agents/
- https://opencode.ai/docs/permissions/
- https://dev.opencode.ai/docs/config

## Interfaces

The stdio server is registered as `codexswap_alpha` and exposes one deliberately narrow tool:

- `codexswap_alpha_review(task)` — bounded, attachment-only review in a private task directory. It cannot inspect the live workspace, edit files, run shell commands, launch nested agents, or access external filesystem locations.

An edit tool is intentionally not exposed in v1. Letting an external model edit the live workspace before Sol review could mutate ignored, untracked, metadata, or linked files that a Git diff would not reliably reveal. A future edit mode requires an isolated worktree/copy and a bounded patch-return workflow.

The task is non-empty UTF-8 text capped at 32 KiB. It is written to a mode-0600 temporary attachment and never placed in process arguments, environment values, logs, or MCP error text. OpenCode receives only fixed arguments and a fixed non-sensitive instruction to complete the attached task.

The runner uses `--pure`, an inline primary-agent definition with a catch-all deny and no workspace file tools, the exact `opencode/x-preview-f-free` model, `max` variant, JSON events, a 15-minute execution deadline, and a combined 2 MiB output budget. OpenCode runs in a private task directory with a private task-owned HOME/XDG tree rather than the live workspace or the user's OpenCode configuration and credentials. The `--file` attachment is the sole review input; Sol must explicitly place any relevant source excerpt in the bounded task. The runner extracts only final text, a sanitized OpenCode session identifier, and bounded tool-call evidence. Malformed, empty, oversized, timed-out, or cancelled runs fail explicitly, followed by bounded teardown.

## Trust boundaries and abuse cases

- GPT output and MCP arguments are untrusted. The server validates the schema and size before launching anything.
- Alpha output is untrusted evidence. It is returned to Sol as text and is never executed by CodexSwap.
- The locally installed OpenCode executable is trusted infrastructure. The remote Alpha model cannot invoke shell, LSP, nested-agent, or other process-launching tools through this profile; a locally replaced binary that deliberately daemonizes outside its assigned process group is outside this boundary.
- The worker does not inherit the MCP server's workspace. It runs in a private task directory and the tool has no path parameter.
- OpenCode receives a catch-all deny. Read, glob, list, grep, edit/write/patch, shell, nested agents, web, LSP, skills, and external-directory access all remain denied; the private `--file` attachment is the sole input.
- The server has bounded input, combined output, execution time, and one active review. Cancellation remains responsive and terminates the exact owned process group, including descendants that remain in that group, before the leader is reaped.
- CodexSwap checks `codexswap_alpha` ownership but does not automatically add or remove it. Current `codex mcp add` overwrites a same-name entry, so the UI provides fresh status and manually reviewed setup/removal guidance rather than an unsafe toggle.
- Native cross-provider role application remains blocked; enabling this tool never relabels Alpha as OpenAI and never edits the parent model.

## Observable contract

```gherkin
Feature: Sol delegates bounded work to 0x Alpha

  Rule: Sol remains the parent authority

    Scenario: Sol requests an Alpha review
      Given the CodexSwap Alpha MCP server is enabled for this Codex session
      When Sol calls the read-only Alpha review tool with a bounded task
      Then OpenCode runs 0x Alpha in a private task directory
      And Alpha cannot inspect the live workspace, edit files, run shell commands, or launch another agent
      And Sol receives a bounded structured result for independent judgment

  Rule: Native incompatible delegation stays blocked

    Scenario: A GPT parent assigns a native Alpha role
      Given the configured Codex parent uses the OpenAI provider
      When a native role assignment selects the bridged Alpha provider
      Then Apply remains disabled
      And CodexSwap explains once that native cross-provider spawn can produce an empty or unreadable child task
      And no role, catalog, or parent configuration is changed

  Rule: Private task content does not leak through process metadata

    Scenario: A task contains private workspace details
      When CodexSwap launches the Alpha worker
      Then the task is absent from process arguments and environment values
      And the temporary attachment is readable only by the current user
      And the attachment is removed after success, failure, timeout, or cancellation

  Rule: Registration is ownership-safe

    Scenario: Another tool already owns the configured server name
      Given `codexswap_alpha` points to a different executable
      When CodexSwap checks Alpha delegation or prepares manual setup guidance
      Then it reports a conflict
      And it does not overwrite or remove the existing registration
```

## Non-goals

- Decrypting or bypassing native Codex collaboration payloads.
- Pretending the external worker is a native Codex subagent.
- Replaying the complete Sol conversation or hidden instructions into Alpha.
- Giving Alpha shell, Git, package-manager, credential, or arbitrary-directory authority.
- Giving Alpha live-workspace edit authority before an isolated patch-return design exists.
- Automatically changing the Codex parent or globally rewriting provider settings.
- Automatically adding or removing the reserved Codex MCP registration.

## Verification gates

- Unit tests for MCP framing, strict schemas, runner configuration, redaction, parsing, bounds, timeout/cancellation, and registration identity.
- Existing native policy, manager, Task Board, bridge, and settings suites remain green.
- A packaged-helper smoke test completes a read-only sentinel through `opencode/x-preview-f-free`, while hostile permission, cancellation/ping, combined-output, process-group, isolated-HOME, and process-metadata probes remain green.
- A fresh adversarial review must pass before the app installs or registers the helper.
- The installed CodexSwap proxy stays live during development; a final replacement is followed by immediate reopen and listener verification.
