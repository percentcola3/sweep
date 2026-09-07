#!/bin/bash
# App bridge: docker system df summary. Read-only.
# TSV: type \t count \t size \t reclaimable (raw human strings from Docker).
# Empty output = docker absent or daemon unreachable; the GUI hides the section.
set -euo pipefail
export LC_ALL=C

DOCKER_BIN=""
if [[ "${MOLE_TEST_MODE:-0}" == "1" && -n "${MOLE_TEST_DOCKER_BIN:-}" ]]; then
    DOCKER_BIN="$MOLE_TEST_DOCKER_BIN"
else
    DOCKER_BIN=$(command -v docker 2>/dev/null || true)
fi
[[ -n "$DOCKER_BIN" && -x "$DOCKER_BIN" ]] || exit 0

# Parse columns from the right because TYPE contains spaces for Local Volumes
# and Build Cache. RECLAIMABLE may itself end with a percentage column.
"$DOCKER_BIN" system df 2>/dev/null | /usr/bin/awk '
    NR > 1 && NF >= 5 {
        if ($NF ~ /^\([0-9.]+%\)$/) {
            reclaimable = $(NF - 1) " " $NF
            size = $(NF - 2)
            total = $(NF - 4)
            type_end = NF - 5
        } else {
            reclaimable = $NF
            size = $(NF - 1)
            total = $(NF - 3)
            type_end = NF - 4
        }
        type = $1
        for (field = 2; field <= type_end; field++) type = type " " $field
        printf "%s\t%s\t%s\t%s\n", type, total, size, reclaimable
    }
'
