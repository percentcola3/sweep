#!/bin/bash
# Image-center inventory. Spotlight is only used to enumerate image candidates;
# metadata is read and formatted by Mole's own scan pipeline.
set -euo pipefail

root="${1:-$HOME}"
limit="${2:-500}"
source "$(dirname "${BASH_SOURCE[0]}")/app_scan_access.sh"
forgesweep_require_scan_path_access "$root" || exit $?
declare -a files=()
if command -v mdfind >/dev/null 2>&1; then
    while IFS= read -r path; do
        [[ -f "$path" ]] || continue
        case "$path" in "$HOME/Library/Developer/"*|"$HOME/.cache/"*|"$HOME/.npm/"*) continue;; esac
        files+=("$path")
        [[ "${#files[@]}" -ge "$limit" ]] && break
    done < <(mdfind -onlyin "$root" "kMDItemContentTypeTree == 'public.image'" 2>/dev/null)
else
    while IFS= read -r -d '' path; do files+=("$path"); [[ "${#files[@]}" -ge "$limit" ]] && break; done < <(find "$root" -type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.heic' -o -iname '*.webp' -o -iname '*.gif' -o -iname '*.tiff' -o -iname '*.raw' \) -print0 2>/dev/null)
fi

if [[ ${#files[@]} -eq 0 ]]; then exit 0; fi
for path in "${files[@]}"; do
    bytes=$(stat -f '%z' "$path" 2>/dev/null || echo 0)
    dimensions=$(sips -g pixelWidth -g pixelHeight "$path" 2>/dev/null | awk '/pixelWidth:/{w=$2} /pixelHeight:/{h=$2} END{if(w && h) printf "%s\t%s",w,h}')
    width="${dimensions%%$'\t'*}"; height="${dimensions#*$'\t'}"
    [[ "$width" =~ ^[0-9]+$ ]] || width=0; [[ "$height" =~ ^[0-9]+$ ]] || height=0
    printf '%s\t%s\t%s\t%s\n' "$bytes" "$width" "$height" "$path"
done
