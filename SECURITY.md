# Security Policy

CodexSwap handles authentication tokens and sits in the request path between Codex and OpenAI. Please report security issues privately.

## Supported versions

Security fixes are applied to the latest published release and the current `main` branch. Older releases may not receive backports.

| Version | Supported |
| --- | --- |
| Latest release | Yes |
| `main` | Yes |
| Older releases | No guaranteed support |

## Reporting a vulnerability

Use [GitHub private vulnerability reporting](https://github.com/M1Vj/CodexSwap/security/advisories/new). Do not open a public issue for suspected credential disclosure, authentication bypass, request-routing flaws, local privilege escalation, or release-pipeline compromise.

Include:

- The affected version or commit.
- Reproduction steps with tokens, account IDs, and email addresses removed.
- Expected and observed behavior.
- Impact and any known workaround.

You should receive an acknowledgment within seven days. Please allow time for a fix and coordinated release before public disclosure.

## Sensitive files

Never attach these files to an issue or discussion:

- `~/.codex/auth.json`
- Files below `~/.codex/accounts/`
- CodexBar managed-home `auth.json` files
- `~/Library/Application Support/CodexSwap/accounts.json`
- Signing certificates, Apple app-specific passwords, or GitHub tokens

Sanitize logs before sharing them. CodexSwap's normal logs should not contain raw credentials, but request headers and verbose third-party output can still be sensitive.
