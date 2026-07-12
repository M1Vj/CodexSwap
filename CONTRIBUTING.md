# Contributing to CodexSwap

Contributions are welcome through GitHub issues and pull requests.

## Requirements

- macOS 14 or newer
- Xcode Command Line Tools with a Swift 6-compatible toolchain
- Git

## Development setup

```bash
git clone https://github.com/M1Vj/CodexSwap.git
cd CodexSwap
swift package resolve
swift test
swift run CodexSwapApp
```

Build the packaged app with:

```bash
./Scripts/build-app.sh
open dist/CodexSwap.app
```

## Pull requests

- Create a focused branch from `main`.
- Add or update tests before changing behavior.
- Keep commits atomic and use Conventional Commit subjects such as `feat:`, `fix:`, `docs:`, `build:`, or `ci:`.
- Run `swift test`, `swift build -c release`, and `git diff --check` before opening a pull request.
- Explain user-visible behavior, security implications, and manual verification.
- Do not include generated `dist/` output.

## Security-sensitive work

Never commit or paste tokens, auth files, account IDs, signing certificates, Apple credentials, or unsanitized logs. Use the private process in [SECURITY.md](SECURITY.md) for vulnerabilities.

## Release changes

Changes to signing, notarization, Homebrew, credential storage, or proxy authentication require an explicit security review. See [docs/RELEASING.md](docs/RELEASING.md) once release tooling is configured.
