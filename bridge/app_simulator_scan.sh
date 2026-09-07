#!/bin/bash
# Read-only CoreSimulator device inventory. stdout is simctl JSON.
set -euo pipefail
export LC_ALL=C

[[ "$#" -eq 0 ]] || { echo "usage: app_simulator_scan.sh" >&2; exit 2; }

XCRUN_BIN=/usr/bin/xcrun
if [[ "${MOLE_TEST_MODE:-0}" == "1" && -n "${MOLE_TEST_XCRUN_BIN:-}" ]]; then
    XCRUN_BIN="$MOLE_TEST_XCRUN_BIN"
fi
[[ -x "$XCRUN_BIN" ]] || exit 0
"$XCRUN_BIN" --find simctl >/dev/null 2>&1 || exit 0
"$XCRUN_BIN" simctl list devices --json
