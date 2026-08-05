#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CARGO_BIN="${CARGO:-cargo}"
RUSTC_BIN="${RUSTC:-rustc}"

"$ROOT/Scripts/verify-vendor.sh"
command -v "$CARGO_BIN" >/dev/null 2>&1 || {
  echo "error: cargo is required to build the vendored Obscura source" >&2
  exit 1
}
command -v "$RUSTC_BIN" >/dev/null 2>&1 || {
  echo "error: rustc is required to build the vendored Obscura source" >&2
  exit 1
}

mkdir -p "$ROOT/.cache/cargo" "$ROOT/Vendor/Obscura/target"
export CARGO_HOME="${CARGO_HOME:-$ROOT/.cache/cargo}"
export CARGO_TARGET_DIR="$ROOT/Vendor/Obscura/target"
export RUSTC="$RUSTC_BIN"

# Reject ambient build substitutions. The exact vendored source and selected
# Rust toolchain must be the only inputs that determine the engine binary.
unset RUSTC_WRAPPER RUSTC_WORKSPACE_WRAPPER RUSTFLAGS CARGO_ENCODED_RUSTFLAGS
unset CARGO_BUILD_TARGET RUSTY_V8_ARCHIVE V8_FROM_SOURCE SCCACHE_DIR SCCACHE_BUCKET

"$CARGO_BIN" build \
  --manifest-path "$ROOT/Vendor/Obscura/Cargo.toml" \
  --locked \
  --release \
  --package obscura-cli \
  --bin obscura

ENGINE="$ROOT/Vendor/Obscura/target/release/obscura"
test -x "$ENGINE" || {
  echo "error: expected engine binary was not produced: $ENGINE" >&2
  exit 1
}
"$ENGINE" --version
"$ROOT/Scripts/verify-vendor.sh"
