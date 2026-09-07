#!/bin/bash
# App bridge: Xcode ecosystem inventory. Read-only.
# TSV: bytes \t kind \t name \t path
#   kind=clean  safe to remove (rebuilds / re-syncs automatically)
#   kind=keep   display only (Archives are needed for symbolication); the
#               apply bridge refuses keep paths.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1090
source "$SCRIPT_DIR/lib/core/common.sh"
# Keep Xcode discovery on the same TCC boundary as every other filesystem
# bridge.  Explicit user-owned Developer roots do not require FDA, while a
# redirected/protected path is skipped instead of triggering a native prompt.
# shellcheck disable=SC1090
source "$SCRIPT_DIR/bin/app_scan_access.sh"

HOME_DIR="${HOME%/}"
[[ -n "$HOME_DIR" ]] || HOME_DIR="/"
load_mole_whitelist "$HOME_DIR"

# A lexical allowlist is not enough for a scanner: a symlinked Xcode root could
# make `du` inventory an unrelated tree and present it as removable.  Walk the
# existing ancestors and reject links before sizing anything.  Missing
# ancestors are fine (the scanner simply emits no row for a non-existent root).
xcode_scan_path_is_physical() {
    local path="${1:-}" probe="" parent=""
    [[ "$path" == /* && ! "$path" =~ [[:cntrl:]] ]] || return 1
    [[ "$path" != *'/../'* && "$path" != */.. ]] || return 1
    case "$path" in
        "$HOME_DIR"|"$HOME_DIR"/*) ;;
        *) return 1 ;;
    esac
    probe="$path"
    while :; do
        [[ ! -L "$probe" ]] || return 1
        [[ "$probe" == "$HOME_DIR" ]] && break
        parent="${probe%/*}"
        [[ -n "$parent" && "$parent" != "$probe" && "$parent" != "/" ]] || return 1
        probe="$parent"
    done
    return 0
}

xcode_scan_path_allowed() {
    local path="${1:-}"
    xcode_scan_path_is_physical "$path" || return 1
    is_path_whitelisted "$path" && return 1
    forgesweep_scan_path_allowed "$path" || return 1
    return 0
}

declare -a emitted_paths=()

emit() {
    local bytes kind name path existing
    kind="$1"; name="$2"; path="$3"
    [[ -e "$path" ]] || return 0
    xcode_scan_path_allowed "$path" || return 0
    # Keep one physical subtree per record. This matters if a user has
    # configured an Xcode directory through an alias or if future roots are
    # nested; duplicate rows otherwise inflate the reclaimable total.
    for existing in "${emitted_paths[@]+${emitted_paths[@]}}"; do
        if [[ "$path" == "$existing" || "$path" == "$existing/"* ]]; then
            return 0
        fi
        if [[ "$existing" == "$path/"* ]]; then
            return 0
        fi
    done
    # BSD du's -P guarantees that a late-created symlink is not followed while
    # the size is calculated. The apply bridge repeats the physical check.
    bytes=$(du -skP "$path" 2>/dev/null | awk '{print $1 * 1024}')
    [[ "$bytes" =~ ^[0-9]+$ ]] || bytes=0
    # Zero-byte rows are noise in both the cleanup and analysis views.
    [[ "$bytes" -gt 0 ]] || return 0
    printf '%s\t%s\t%s\t%s\n' "$bytes" "$kind" "$name" "$path"
    emitted_paths+=("$path")
}

emit clean "Xcode DerivedData"     "$HOME_DIR/Library/Developer/Xcode/DerivedData"
emit clean "Xcode module caches"   "$HOME_DIR/Library/Caches/com.apple.dt.Xcode"
emit clean "Simulator caches"      "$HOME_DIR/Library/Developer/CoreSimulator/Caches"
emit clean "iOS DeviceSupport"     "$HOME_DIR/Library/Developer/Xcode/iOS DeviceSupport"
emit clean "watchOS DeviceSupport" "$HOME_DIR/Library/Developer/Xcode/watchOS DeviceSupport"
emit clean "tvOS DeviceSupport"    "$HOME_DIR/Library/Developer/Xcode/tvOS DeviceSupport"
emit keep  "Xcode Archives"        "$HOME_DIR/Library/Developer/Xcode/Archives"
