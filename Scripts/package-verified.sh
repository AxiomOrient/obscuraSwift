#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="${1:-$ROOT/Artifacts}"
REPORT="$ROOT/COMPLETION_REPORT.md"

cd "$ROOT"
test -f "$REPORT" || {
  echo "error: COMPLETION_REPORT.md is missing" >&2
  exit 1
}
grep -Fxq 'Status: COMPLETE' "$REPORT" || {
  echo "error: completion report is not COMPLETE" >&2
  exit 1
}
git diff --quiet && git diff --cached --quiet && [[ -z "$(git status --porcelain)" ]] || {
  echo "error: working tree must be clean" >&2
  exit 1
}

"$ROOT/Scripts/verify-all.sh"
revision="$(git rev-parse HEAD)"
short="$(git rev-parse --short=12 HEAD)"
name="obscura-swift-$short"
mkdir -p "$OUTPUT_DIR"
archive="$OUTPUT_DIR/$name.zip"
checksum="$archive.sha256"
rm -f "$archive" "$checksum"
git archive --format=zip --prefix="$name/" --output="$archive" "$revision"

work="$(mktemp -d "${TMPDIR:-/tmp}/obscura-clean-extraction.XXXXXX")"
cleanup() { rm -rf "$work"; }
trap cleanup EXIT
unzip -q "$archive" -d "$work"
(
  cd "$work/$name"
  export CARGO_HOME="$work/cargo-home"
  ./Scripts/verify-all.sh
)
sha256sum "$archive" > "$checksum"
echo "verified archive: $archive"
cat "$checksum"
