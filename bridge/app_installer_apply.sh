#!/bin/bash
# Apply explicit installer-file selections. Records are NUL-delimited
# path/identity pairs captured at confirmation time.
set -euo pipefail
export LC_ALL=C LANG=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1090
source "$SCRIPT_DIR/lib/core/common.sh"
# shellcheck disable=SC1090
source "$SCRIPT_DIR/bin/app_runtime_guard.sh"

export MOLE_CURRENT_COMMAND="clean"
simplemole_configure_delete_mode
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

removed=0
skipped=0
failed=0

has_unsafe_path_syntax() {
    local value="$1"
    [[ "$value" =~ [[:cntrl:]] ]] && return 0
    [[ "$value" =~ (^|/)\.\.?(/|$) ]]
}

is_installer_zip() {
    local archive="$1"
    if command -v zipinfo >/dev/null 2>&1; then
        zipinfo -1 "$archive" 2>/dev/null |
            awk 'NR <= 50 && /\.(app|pkg|dmg|xip)(\/|$)/{found=1} END{exit found ? 0 : 1}'
    elif command -v unzip >/dev/null 2>&1; then
        unzip -Z -1 "$archive" 2>/dev/null |
            awk 'NR <= 50 && /\.(app|pkg|dmg|xip)(\/|$)/{found=1} END{exit found ? 0 : 1}'
    else
        return 1
    fi
}

# Print the configured lexical root that still physically contains the path.
matching_root() {
    local path="$1" root relative physical_root physical_parent path_parent
    path_parent="${path%/*}"
    [[ -n "$path_parent" ]] || path_parent="/"

    for root in "${roots[@]}"; do
        [[ -d "$root" && ! -L "$root" ]] || continue
        case "$path" in
            "$root"/*) ;;
            *) continue ;;
        esac
        relative="${path#"$root"/}"
        [[ -n "$relative" ]] || continue
        # app_installer_scan.sh only emits files at find depth one or two.
        case "$relative" in */*/*) continue ;; esac

        physical_root=$(cd -P "$root" 2>/dev/null && pwd -P) || physical_root=""
        physical_parent=$(cd -P "$path_parent" 2>/dev/null && pwd -P) || physical_parent=""
        [[ -n "$physical_root" && "$physical_root" == "$root" ]] || continue
        # The scanner does not follow directory symlinks. Apply must not gain
        # a wider route through an alias, even when that alias lands back under root.
        [[ "$physical_parent" == "$path_parent" ]] || continue
        case "$physical_parent" in
            "$physical_root"|"$physical_root"/*)
                printf '%s\n' "$root"
                return 0
                ;;
        esac
    done
    return 1
}

while IFS= read -r -d '' path; do
    identity=""
    if ! IFS= read -r -d '' identity; then
        echo "error: missing identity for installer path: $path"
        failed=$((failed + 1))
        break
    fi
    if [[ "$path" != /* || "$path" == */ ]] || has_unsafe_path_syntax "$path";
    then
        echo "error: invalid installer path: $path"
        failed=$((failed + 1))
        continue
    fi
    if [[ ! "$identity" =~ ^[0-9]+:[0-9]+:[0-9]+$ ]]; then
        echo "error: invalid identity for installer path: $path"
        failed=$((failed + 1))
        continue
    fi
    if [[ -L "$path" || ! -f "$path" ]]; then
        echo "error: installer candidate is not a regular file: $path"
        failed=$((failed + 1))
        continue
    fi
    if ! root=$(matching_root "$path"); then
        echo "error: installer path is outside an allowed physical root: $path"
        failed=$((failed + 1))
        continue
    fi

    extension=$(printf '%s' "${path##*.}" | tr '[:upper:]' '[:lower:]')
    case "$extension" in
        dmg|pkg|mpkg|iso|xip) ;;
        zip)
            if ! is_installer_zip "$path"; then
                echo "error: zip is not an installer archive: $path"
                failed=$((failed + 1))
                continue
            fi
            ;;
        *)
            echo "error: unsupported installer extension: $path"
            failed=$((failed + 1))
            continue
            ;;
    esac

    current_identity=$("$STAT_BSD" -f%d:%i:%m "$path" 2>/dev/null || true)
    if [[ "$current_identity" != "$identity" ]]; then
        echo "error: installer path identity changed: $path"
        failed=$((failed + 1))
        continue
    fi
    if is_path_whitelisted "$path"; then
        skipped=$((skipped + 1))
        continue
    fi
    if mole_delete "$path" false "$identity"; then
        removed=$((removed + 1))
    else
        failed=$((failed + 1))
    fi
done

printf 'removed=%s\nskipped=%s\nfailed=%s\n' "$removed" "$skipped" "$failed"
[[ "$failed" -eq 0 ]]
