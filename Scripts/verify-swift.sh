#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
export TERM="${TERM:-xterm}"

if command -v swift-format >/dev/null 2>&1; then
  swift-format lint --strict --recursive Sources Tests Package.swift
else
  swift format lint --strict --recursive Sources Tests Package.swift
fi
swift package clean
swift build -c debug -Xswiftc -warnings-as-errors
swift test -c debug --jobs 1 -Xswiftc -warnings-as-errors
"$ROOT/Scripts/verify-cli-fixture.sh" debug

swift package clean
swift build -c release -Xswiftc -warnings-as-errors
swift test -c release --jobs 1 -Xswiftc -warnings-as-errors
"$ROOT/Scripts/verify-cli-fixture.sh" release
