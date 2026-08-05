#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="${1:-debug}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/obscura-cli-fixture.XXXXXX")"
PID_FILE="$WORK/fixture.pid"
REQUEST_LOG="$WORK/requests.jsonl"
WRAPPER="$WORK/fixture-wrapper.sh"

cleanup() {
  if [[ -f "$PID_FILE" ]]; then
    pid="$(cat "$PID_FILE" 2>/dev/null || true)"
    if [[ "$pid" =~ ^[0-9]+$ ]]; then
      kill -KILL -- "-$pid" 2>/dev/null || true
      kill -KILL "$pid" 2>/dev/null || true
    fi
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

cat > "$WRAPPER" <<WRAPPER
#!/bin/sh
set -eu
export OBSCURA_FIXTURE_MODE=normal
export OBSCURA_FIXTURE_DELAY_SECONDS=0.05
export OBSCURA_FIXTURE_PID_FILE='$PID_FILE'
export OBSCURA_FIXTURE_REQUEST_LOG='$REQUEST_LOG'
exec python3 '$ROOT/Tests/ObscuraKitTests/Integration/fixture_engine.py' "\$@"
WRAPPER
chmod 700 "$WRAPPER"

swift build --package-path "$ROOT" -c "$CONFIGURATION" -Xswiftc -warnings-as-errors
BIN_PATH="$(swift build --package-path "$ROOT" -c "$CONFIGURATION" --show-bin-path)"
OUTPUT="$($BIN_PATH/obscura-swift doctor --engine "$WRAPPER")"
python3 - "$OUTPUT" <<'PY'
import json
import sys
value = json.loads(sys.argv[1])
if value != {"status": "ok", "text": "ready", "title": "ObscuraKit Doctor"}:
    raise SystemExit(f"unexpected doctor output: {value!r}")
print("CLI fixture doctor verified")
PY

for _ in $(seq 1 100); do
  if [[ ! -f "$PID_FILE" ]] || ! kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
    exit 0
  fi
  sleep 0.02
done
echo "error: CLI fixture child remained alive" >&2
exit 1
