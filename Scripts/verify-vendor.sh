#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

python3 - "$ROOT" <<'PY'
from __future__ import annotations

import hashlib
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1]).resolve()
vendor = root / "Vendor" / "Obscura"
manifest = root / "Vendor" / "OBSCURA_FILES.sha256"
provenance_path = root / "Vendor" / "OBSCURA_SOURCE.json"

if not vendor.is_dir():
    raise SystemExit("vendor verification failed: Vendor/Obscura is missing")
if not manifest.is_file() or not provenance_path.is_file():
    raise SystemExit("vendor verification failed: manifest or provenance is missing")

provenance = json.loads(provenance_path.read_text(encoding="utf-8"))
if provenance.get("policy") != "immutable-vendored-source":
    raise SystemExit("vendor verification failed: immutable policy is missing")
if not provenance.get("sourceArchiveSHA256"):
    raise SystemExit("vendor verification failed: source archive hash is missing")

expected: dict[pathlib.Path, str] = {}
for line_number, line in enumerate(manifest.read_text(encoding="utf-8").splitlines(), 1):
    if not line:
        continue
    try:
        digest, relative = line.split("  ", 1)
    except ValueError as error:
        raise SystemExit(f"vendor verification failed: malformed manifest line {line_number}") from error
    path = pathlib.Path(relative)
    if path.is_absolute() or ".." in path.parts:
        raise SystemExit(f"vendor verification failed: unsafe manifest path {relative}")
    if not relative.startswith("Vendor/Obscura/"):
        raise SystemExit(f"vendor verification failed: out-of-bound manifest path {relative}")
    expected[path] = digest

actual: set[pathlib.Path] = set()
for path in vendor.rglob("*"):
    relative = path.relative_to(root)
    if relative.parts[:3] == ("Vendor", "Obscura", "target"):
        continue
    if path.is_symlink():
        raise SystemExit(f"vendor verification failed: symbolic link is forbidden: {relative}")
    if path.is_file():
        actual.add(relative)

missing = sorted(expected.keys() - actual)
extra = sorted(actual - expected.keys())
if missing or extra:
    details = []
    if missing:
        details.append("missing=" + ", ".join(map(str, missing[:10])))
    if extra:
        details.append("extra=" + ", ".join(map(str, extra[:10])))
    raise SystemExit("vendor verification failed: file set mismatch: " + "; ".join(details))

for relative, wanted in sorted(expected.items(), key=lambda item: str(item[0])):
    digest = hashlib.sha256((root / relative).read_bytes()).hexdigest()
    if digest != wanted:
        raise SystemExit(f"vendor verification failed: checksum mismatch: {relative}")

print(f"vendor source verified: {len(expected)} files")
print(f"source archive sha256: {provenance['sourceArchiveSHA256']}")
PY
