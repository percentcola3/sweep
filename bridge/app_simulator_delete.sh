#!/bin/bash
# Delete explicitly selected, stopped CoreSimulator devices.
# stdin: NUL-delimited simulator UUIDs. Running and unknown states are protected.
set -euo pipefail
export LC_ALL=C

[[ "$#" -eq 0 ]] || { echo "usage: app_simulator_delete.sh" >&2; exit 2; }

XCRUN_BIN=/usr/bin/xcrun
if [[ "${MOLE_TEST_MODE:-0}" == "1" && -n "${MOLE_TEST_XCRUN_BIN:-}" ]]; then
    XCRUN_BIN="$MOLE_TEST_XCRUN_BIN"
fi
[[ -x "$XCRUN_BIN" ]] || { echo "simctl unavailable" >&2; exit 127; }
"$XCRUN_BIN" --find simctl >/dev/null 2>&1 || { echo "simctl unavailable" >&2; exit 127; }

removed=0
skipped=0
failed=0
while IFS= read -r -d '' udid; do
    if [[ ! "$udid" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]]; then
        failed=$((failed + 1))
        continue
    fi

    # Re-read state immediately before the fixed destructive command. Only an
    # exact Shutdown state is accepted; Booted, transitional and missing rows
    # are protected. simctl itself performs a final state check as well.
    # Match only the device metadata suffix. A different device name may contain
    # arbitrary UUID/state-looking text, so substring matches are not authority.
    device_line=$("$XCRUN_BIN" simctl list devices 2>/dev/null \
        | /usr/bin/awk -v expected="$udid" '
            $0 ~ "\\(" expected "\\)[[:space:]]+\\(Shutdown\\)([[:space:]]+\\(unavailable.*\\))?[[:space:]]*$" {
                print
                exit
            }
        ') || device_line=""
    if [[ -z "$device_line" ]]; then
        skipped=$((skipped + 1))
        continue
    fi

    if "$XCRUN_BIN" simctl delete "$udid"; then
        removed=$((removed + 1))
    else
        failed=$((failed + 1))
    fi
done

printf 'removed=%s\nskipped=%s\nfailed=%s\n' "$removed" "$skipped" "$failed"
[[ "$failed" -eq 0 ]]
