#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/forgesweep-scan-build.XXXXXX")"
FIXTURE_DIR="$(mktemp -d "$ROOT_DIR/.cleanup-scan-fixture.XXXXXX")"
trap 'rm -rf "$TEST_DIR" "$FIXTURE_DIR"' EXIT
swiftc -O -target "$(uname -m)-apple-macos13.0" \
    -framework AppKit -framework IOKit \
    "$ROOT_DIR/SimpleMole/Models.swift" \
    "$ROOT_DIR/SimpleMole/Services/DeletionPlan.swift" \
    "$ROOT_DIR/SimpleMole/Services/CleanupRiskPolicy.swift" \
    "$ROOT_DIR/SimpleMole/Services/NativeCore.swift" \
    "$ROOT_DIR/SimpleMole/Services/CleanupScanWorker.swift" \
    "$ROOT_DIR/SimpleMole/Services/SystemMetrics.swift" \
    "$ROOT_DIR/script/CleanupRiskTestL10nStub.swift" \
    "$ROOT_DIR/script/CleanupScanTests.swift" \
    -o "$TEST_DIR/cleanup-scan-tests"
"$TEST_DIR/cleanup-scan-tests" "$FIXTURE_DIR"
