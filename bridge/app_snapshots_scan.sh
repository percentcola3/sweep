#!/bin/bash
# App bridge: APFS purgeable space + local Time Machine snapshots. Read-only.
# Output:
#   purgeable \t <bytes>
#   snapshot  \t <date-string>
set -euo pipefail
export LC_ALL=C

purgeable=$(diskutil info -plist / 2>/dev/null \
    | plutil -extract Purgeable raw - 2>/dev/null || echo 0)
[[ "$purgeable" =~ ^[0-9]+$ ]] || purgeable=0
printf 'purgeable\t%s\n' "$purgeable"

while IFS= read -r date_part; do
    [[ -n "$date_part" ]] && printf 'snapshot\t%s\n' "$date_part"
done < <(tmutil listlocalsnapshots / 2>/dev/null \
    | sed -n 's/^com\.apple\.TimeMachine\.\(.*\)\.local$/\1/p')
