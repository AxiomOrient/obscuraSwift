#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENGINE="$ROOT/Vendor/Obscura/target/release/obscura"
test -x "$ENGINE" || {
  echo "error: vendored engine is not built; run Scripts/build-vendored-obscura.sh" >&2
  exit 1
}

"$ROOT/Scripts/verify-vendor.sh"
swift build --package-path "$ROOT" -c release -Xswiftc -warnings-as-errors
BIN_PATH="$(swift build --package-path "$ROOT" -c release --show-bin-path)"
OUTPUT="$($BIN_PATH/obscura-swift doctor --repository-root "$ROOT")"
python3 - "$OUTPUT" <<'PY'
import json
import sys
value = json.loads(sys.argv[1])
if value != {"status": "ok", "text": "ready", "title": "ObscuraKit Doctor"}:
    raise SystemExit(f"unexpected runtime doctor output: {value!r}")
print("vendored Obscura runtime verified")
PY
