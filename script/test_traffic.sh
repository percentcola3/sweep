#!/usr/bin/env bash
# Deterministic traffic accounting checks; no app or live network sampling.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TRAFFIC_TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/forgesweep-traffic-tests.XXXXXX")"
trap 'rm -rf "$TRAFFIC_TEST_ROOT"' EXIT
arch="$(uname -m)"
sources=(
    "$ROOT_DIR/SimpleMole/Models.swift"
    "$ROOT_DIR/SimpleMole/Services/DeletionPlan.swift"
    "$ROOT_DIR/SimpleMole/Services/CleanupRiskPolicy.swift"
    "$ROOT_DIR/SimpleMole/Services/Parsers.swift"
    "$ROOT_DIR/SimpleMole/Services/TrafficLedger.swift"
    "$ROOT_DIR/SimpleMole/Services/TrafficAttribution.swift"
    "$ROOT_DIR/script/CleanupRiskTestL10nStub.swift"
)
for suite in TrafficLedger TrafficAttribution; do
    swiftc -target "$arch-apple-macos13.0" -module-cache-path "$TRAFFIC_TEST_ROOT/module-cache" \
        "${sources[@]}" "$ROOT_DIR/script/${suite}Tests.swift" -o "$TRAFFIC_TEST_ROOT/$suite"
    "$TRAFFIC_TEST_ROOT/$suite"
done
swiftc -target "$arch-apple-macos13.0" -module-cache-path "$TRAFFIC_TEST_ROOT/module-cache" \
    "${sources[@]}" "$ROOT_DIR/SimpleMole/Services/TrafficMonitor.swift" \
    "$ROOT_DIR/script/TrafficStoreTestStubs.swift" "$ROOT_DIR/script/TrafficStoreTests.swift" \
    -o "$TRAFFIC_TEST_ROOT/TrafficStore"
"$TRAFFIC_TEST_ROOT/TrafficStore"
