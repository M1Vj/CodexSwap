#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: Scripts/build-universal.sh"
  echo "Builds arm64 and x86_64 release products, combines them, and assembles dist/CodexSwap.app."
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi
[[ $# -eq 0 ]] || { usage >&2; exit 2; }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRATCH="${UNIVERSAL_SCRATCH_DIR:-$ROOT/.build/codexswap-universal}"
PRODUCTS="$SCRATCH/products"

rm -rf "$PRODUCTS"
mkdir -p "$PRODUCTS"

build_arch() {
  local arch="$1"
  local path="$SCRATCH/$arch"
  swift build --package-path "$ROOT" --scratch-path "$path" -c release --arch "$arch" --product CodexSwapApp
  swift build --package-path "$ROOT" --scratch-path "$path" -c release --arch "$arch" --product swapd
  swift build --package-path "$ROOT" --scratch-path "$path" -c release --arch "$arch" --show-bin-path
}

echo "› building arm64 release products…"
ARM_BIN="$(build_arch arm64 | tail -n 1)"
echo "› building x86_64 release products…"
INTEL_BIN="$(build_arch x86_64 | tail -n 1)"

for product in CodexSwapApp swapd; do
  lipo -create "$ARM_BIN/$product" "$INTEL_BIN/$product" -output "$PRODUCTS/$product"
  chmod 755 "$PRODUCTS/$product"
  lipo "$PRODUCTS/$product" -verify_arch arm64 x86_64
done

echo "› assembling universal application…"
BUILD_PRODUCTS_DIR="$PRODUCTS" "$ROOT/Scripts/build-app.sh"

echo "✓ universal app: $ROOT/dist/CodexSwap.app"
