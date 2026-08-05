#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
"$ROOT/Scripts/verify-vendor.sh"
"$ROOT/Scripts/verify-process-boundary.sh"
"$ROOT/Scripts/build-vendored-obscura.sh"
"$ROOT/Scripts/verify-swift.sh"
"$ROOT/Scripts/verify-runtime.sh"
"$ROOT/Scripts/verify-vendor.sh"
