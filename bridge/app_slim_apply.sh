#!/bin/bash
# NUL-delimited action|path/identity pairs are bound at confirmation time.
set -euo pipefail
is_image() { case "$1" in *.jpg|*.JPG|*.jpeg|*.JPEG|*.png|*.PNG|*.heic|*.HEIC|*.webp|*.WEBP|*.tiff|*.TIFF) return 0;; *) return 1;; esac; }
is_rooted() { case "$1" in "$HOME/Pictures/"*|"$HOME/Desktop/"*|"$HOME/Downloads/"*) return 0;; *) return 1;; esac; }
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; source "$SCRIPT_DIR/lib/core/common.sh"
export MOLE_CURRENT_COMMAND="clean" MOLE_DELETE_MODE="trash"
load_mole_whitelist
removed=0; skipped=0; failed=0
queued_count=0
queued_paths=()
queued_operations=()
queued_identities=()
while IFS= read -r -d '' encoded; do
    identity=""
    if ! IFS= read -r -d '' identity; then
        echo "error: missing identity for image action: $encoded"
        failed=$((failed + 1))
        break
    fi
    if [[ ! "$identity" =~ ^[0-9]+:[0-9]+:[0-9]+$ ]]; then
        failed=$((failed + 1))
        continue
    fi
    operation="${encoded%%|*}"; path="${encoded#*|}"
    case "$operation" in duplicate|compress) ;; *) failed=$((failed + 1)); continue;; esac
    found=-1
    for ((i = 0; i < queued_count; i++)); do
        if [[ "${queued_paths[$i]}" == "$path" ]]; then found=$i; break; fi
    done
    if [[ "$found" -ge 0 ]]; then
        if [[ "${queued_identities[$found]}" != "$identity" ]]; then
            queued_identities[$found]=""
            failed=$((failed + 1))
            continue
        fi
        # Deleting a duplicate takes precedence regardless of input order.
        [[ "$operation" == "duplicate" ]] && queued_operations[$found]="duplicate"
        skipped=$((skipped + 1))
        continue
    fi
    queued_paths[$queued_count]="$path"
    queued_operations[$queued_count]="$operation"
    queued_identities[$queued_count]="$identity"
    queued_count=$((queued_count + 1))
done

for ((i = 0; i < queued_count; i++)); do
    path="${queued_paths[$i]}"; operation="${queued_operations[$i]}"; identity="${queued_identities[$i]}"
    [[ -n "$identity" ]] || continue
    if ! is_rooted "$path" || ! is_image "$path"; then failed=$((failed + 1)); continue; fi
    if [[ ! -f "$path" || -L "$path" ]]; then failed=$((failed + 1)); continue; fi
    if is_path_whitelisted "$path"; then skipped=$((skipped + 1)); continue; fi
    current_identity=$("$STAT_BSD" -f%d:%i:%m "$path" 2>/dev/null || true)
    [[ "$current_identity" == "$identity" ]] || { failed=$((failed + 1)); continue; }
    if [[ "$operation" == "duplicate" ]]; then
        if mole_delete "$path" false "$identity"; then removed=$((removed + 1)); else failed=$((failed + 1)); fi
    elif [[ "${MOLE_IMAGE_MODE:-copy}" == "replace" ]]; then
        current_identity=$("$STAT_BSD" -f%d:%i:%m "$path" 2>/dev/null || true)
        [[ "$current_identity" == "$identity" ]] || { failed=$((failed + 1)); continue; }
        if sips -Z 2400 --setProperty formatOptions 75 "$path" >/dev/null 2>&1; then removed=$((removed + 1)); else failed=$((failed + 1)); fi
    else
        directory="${path%/*}"; filename="${path##*/}"; stem="${filename%.*}"; ext="${filename##*.}"
        destination="$directory/${stem}-compressed.${ext}"
        index=1; while [[ -e "$destination" ]]; do destination="$directory/${stem}-compressed-$index.${ext}"; index=$((index + 1)); done
        current_identity=$("$STAT_BSD" -f%d:%i:%m "$path" 2>/dev/null || true)
        [[ "$current_identity" == "$identity" ]] || { failed=$((failed + 1)); continue; }
        if sips -Z 2400 --setProperty formatOptions 75 "$path" --out "$destination" >/dev/null 2>&1; then removed=$((removed + 1)); else failed=$((failed + 1)); fi
    fi
done
printf 'removed=%s\nskipped=%s\nfailed=%s\n' "$removed" "$skipped" "$failed"
[[ "$failed" -eq 0 ]]
