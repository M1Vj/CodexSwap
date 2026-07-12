#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

fail() { echo "repository-config test failed: $*" >&2; exit 1; }

for file in .github/workflows/ci.yml .github/workflows/release.yml .github/CODEOWNERS \
  .github/dependabot.yml .github/pull_request_template.md \
  .github/ISSUE_TEMPLATE/bug_report.yml .github/ISSUE_TEMPLATE/feature_request.yml \
  LICENSE SECURITY.md PRIVACY.md CONTRIBUTING.md CODE_OF_CONDUCT.md CHANGELOG.md \
  docs/RELEASING.md docs/TROUBLESHOOTING.md; do
  [[ -f "$file" ]] || fail "missing $file"
done

ruby -e 'require "yaml"; ARGV.each { |path| YAML.parse_file(path) }' \
  .github/workflows/ci.yml .github/workflows/release.yml .github/dependabot.yml \
  .github/ISSUE_TEMPLATE/bug_report.yml .github/ISSUE_TEMPLATE/feature_request.yml

grep -Fq 'permissions:' .github/workflows/ci.yml || fail "CI must declare least-privilege permissions"
grep -Fq 'contents: read' .github/workflows/ci.yml || fail "CI must only read repository contents"
[[ "$(grep -F 'runs-on: macos-15' .github/workflows/ci.yml .github/workflows/release.yml | wc -l | tr -d ' ')" == "2" ]] \
  || fail "Swift 6 workflows must use the macOS 15 runner"
[[ "$(grep -F 'uses: actions/checkout@9c091bb21b7c1c1d1991bb908d89e4e9dddfe3e0' .github/workflows/ci.yml .github/workflows/release.yml | wc -l | tr -d ' ')" == "2" ]] \
  || fail "workflows must pin checkout v7.0.0 to its immutable SHA"
grep -A6 -F 'Check out tagged source' .github/workflows/release.yml | grep -Fq 'persist-credentials: false' \
  || fail "release checkout must not persist a write credential"
grep -Fq 'gh auth setup-git' .github/workflows/release.yml || fail "cask publication does not explicitly configure git authentication"
grep -Fq 'contents: write' .github/workflows/release.yml || fail "release workflow must declare release permission"
grep -Fq 'workflow_dispatch:' .github/workflows/ci.yml || fail "CI must support explicit cask validation"
grep -Fq 'actions: write' .github/workflows/release.yml || fail "release workflow cannot dispatch cask CI"
grep -Fq 'DEVELOPER_ID_CERTIFICATE_BASE64' .github/workflows/release.yml || fail "release workflow has no Developer ID certificate input"
grep -Fq 'APPLE_API_KEY_P8_BASE64' .github/workflows/release.yml || fail "release workflow has no notarization API key input"
grep -A2 -F 'REQUIRE_NOTARIZATION:' .github/workflows/release.yml | grep -Fq '"1"' || fail "release verification is not fail-closed"
grep -A2 -F 'REQUIRE_GATEKEEPER:' .github/workflows/release.yml | grep -Fq '"1"' || fail "Gatekeeper verification is not fail-closed"
grep -Fq 'gh workflow run ci.yml' .github/workflows/release.yml || fail "generated cask does not receive an explicit CI run"
grep -Fq 'gh run watch "$RUN_ID" --exit-status' .github/workflows/release.yml || fail "cask publication does not wait for CI"
grep -Fq 'git merge-base --is-ancestor "$GITHUB_SHA" origin/main' .github/workflows/release.yml || fail "release tags are not restricted to main"
grep -Fq 'git cat-file -t "refs/tags/$RELEASE_TAG"' .github/workflows/release.yml || fail "release workflow does not require annotated tags"
grep -Fq 'brew tap-new' .github/workflows/release.yml || fail "release workflow does not style-check the cask inside a tap"
grep -Fq 'mkdir -p "$TAP_PATH/Casks"' .github/workflows/release.yml || fail "temporary tap does not create its Casks directory"
if grep -Fq 'APPLE_APP_PASSWORD' .github/workflows/release.yml; then
  fail "release workflow must use a key file, not an Apple password in process arguments"
fi

grep -Fq 'brew install --cask codexswap' README.md || fail "README has no Homebrew install command"
grep -Fq 'Route Codex through CodexSwap' README.md || fail "README has no terminal-free setup path"
grep -Fq 'REQUIRE_NOTARIZATION' docs/RELEASING.md || fail "release guide does not document fail-closed verification"

for script in Scripts/*.sh; do
  [[ "$(head -n 1 "$script")" == '#!/usr/bin/env bash' ]] || fail "$script has no Bash shebang"
done

echo "repository-config tests passed"
