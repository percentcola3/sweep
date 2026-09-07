#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/core/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/app_scan_access.sh"
load_mole_whitelist

roots=("$HOME/Pictures" "$HOME/Desktop" "$HOME/Downloads")
tmp="$(mktemp "${TMPDIR:-/tmp}/mole-images.XXXXXX")"
trap 'rm -f "$tmp"' EXIT
for root in "${roots[@]}"; do
    forgesweep_scan_path_allowed "$root" || continue
    [[ -d "$root" ]] || continue
    find "$root" -type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.heic' -o -iname '*.webp' -o -iname '*.tiff' \) -size +2M -print0 2>/dev/null
done | while IFS= read -r -d '' path; do
    is_path_whitelisted "$path" && continue
    hash=$(shasum -a 256 "$path" 2>/dev/null | awk '{print $1}') || continue
    bytes=$(stat -f '%z' "$path" 2>/dev/null || echo 0)
    printf '%s\t%s\t%s\n' "$bytes" "$hash" "$path" >> "$tmp"
done
awk -F '\t' 'seen[$2]++ { printf "%s\t图片重复文件 · %s\tduplicate|%s\n", $1, $2, $3 }' "$tmp"
# Only the first file for a content hash is a compression candidate. Remaining
# copies are deletion candidates above, so one path never receives two actions.
awk -F '\t' '!seen[$2]++ { printf "%s\t图片压缩候选\tcompress|%s\n", $1, $3 }' "$tmp"
