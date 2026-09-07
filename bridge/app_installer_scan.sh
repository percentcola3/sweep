#!/bin/bash
# Installer candidates for the regular disk-cleanup scan.
set -euo pipefail
export LC_ALL=C LANG=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/core/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/app_scan_access.sh"
load_mole_whitelist

roots=(
    "$HOME/Downloads" "$HOME/Desktop" "$HOME/Documents" "$HOME/Public"
    "$HOME/Library/Downloads" "/Users/Shared" "/Users/Shared/Downloads"
    "$HOME/Library/Caches/Homebrew"
    "$HOME/Library/Mobile Documents/com~apple~CloudDocs/Downloads"
    "$HOME/Library/Containers/com.apple.mail/Data/Library/Mail Downloads"
    "$HOME/Library/Application Support/Telegram Desktop"
    "$HOME/Downloads/Telegram Desktop"
)

is_installer_zip() {
    local archive="$1"
    if command -v zipinfo >/dev/null 2>&1; then
        zipinfo -1 "$archive" 2>/dev/null | awk 'NR <= 50 && /\.(app|pkg|dmg|xip)(\/|$)/{found=1} END{exit found ? 0 : 1}'
    elif command -v unzip >/dev/null 2>&1; then
        unzip -Z -1 "$archive" 2>/dev/null | awk 'NR <= 50 && /\.(app|pkg|dmg|xip)(\/|$)/{found=1} END{exit found ? 0 : 1}'
    else
        return 1
    fi
}

seen_paths=""
for root in "${roots[@]}"; do
    forgesweep_scan_path_allowed "$root" || continue
    [[ -d "$root" ]] || continue
    while IFS= read -r -d '' file; do
        [[ -L "$file" ]] && continue
        is_path_whitelisted "$file" && continue
        case "$seen_paths" in *$'\n'"$file"$'\n'*) continue;; esac
        case "$file" in *.zip) is_installer_zip "$file" 2>/dev/null || continue;; esac
        seen_paths="${seen_paths}"$'\n'"${file}"$'\n'
        bytes=$(stat -f '%z' "$file" 2>/dev/null || echo 0)
        [[ "$bytes" =~ ^[0-9]+$ ]] || bytes=0
        printf '%s\t安装包文件\t%s\n' "$bytes" "$file"
    done < <(find "$root" -maxdepth 2 -type f \( -iname '*.dmg' -o -iname '*.pkg' -o -iname '*.mpkg' -o -iname '*.iso' -o -iname '*.xip' -o -iname '*.zip' \) -print0 2>/dev/null)
done
