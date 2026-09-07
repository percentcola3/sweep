#!/bin/bash
# App bridge: ask Time Machine to thin local snapshots (owner command).
# Runs privileged (admin) via the GUI's osascript wrapper; prints the
# remaining snapshot dates so the GUI can refresh its list.
set -euo pipefail
export LC_ALL=C

# Urgency 4 with a huge threshold = thin as much as APFS safely allows.
tmutil thinlocalsnapshots / 999999999999999 4 >/dev/null

tmutil listlocalsnapshots / 2>/dev/null \
    | sed -n 's/^com\.apple\.TimeMachine\.\(.*\)\.local$/\1/p' || true
