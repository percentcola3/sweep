#!/bin/bash
# App bridge: clean user-reviewed Xcode build artifacts.
# Path/identity pairs arrive NUL-delimited on stdin. Only paths under the clean roots below
# are accepted; Archives (keep) and anything else are skipped.
set -euo pipefail

HOME_DIR="${HOME%/}"
[[ -n "$HOME_DIR" ]] || HOME_DIR="/"
allowed=(
    "$HOME_DIR/Library/Developer/Xcode/DerivedData"
    "$HOME_DIR/Library/Caches/com.apple.dt.Xcode"
    "$HOME_DIR/Library/Developer/CoreSimulator/Caches"
    "$HOME_DIR/Library/Developer/Xcode/iOS DeviceSupport"
    "$HOME_DIR/Library/Developer/Xcode/watchOS DeviceSupport"
    "$HOME_DIR/Library/Developer/Xcode/tvOS DeviceSupport"
)

# Recheck the physical ancestor chain immediately before deletion.  The
# scanner and the UI bind a plan to a path identity, but a symlink swap between
# those phases must still fail closed rather than deleting outside the Xcode
# cache roots.
simplemole_xcode_path_is_physical() {
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

is_allowed() {
    local candidate="$1" root
    for root in "${allowed[@]}"; do
        [[ "$candidate" == "$root" || "$candidate" == "$root"/* ]] && return 0
    done
    return 1
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1090
source "$SCRIPT_DIR/lib/core/common.sh"
source "$SCRIPT_DIR/bin/app_runtime_guard.sh"
export MOLE_CURRENT_COMMAND="clean"
simplemole_configure_delete_mode
load_mole_whitelist

removed=0
skipped=0
failed=0

simplemole_xcode_path_guard() {
    local candidate="$1" state=0
    if [[ "${MOLE_TEST_MODE:-0}" == "1" && -n "${SIMPLEMOLE_TEST_FINAL_GUARD_LOG:-}" ]]; then
        printf 'xcode\n' >> "$SIMPLEMOLE_TEST_FINAL_GUARD_LOG"
    fi
    simplemole_xcode_path_is_physical "$candidate" || return 1
    load_mole_whitelist
    is_path_whitelisted "$candidate" && return 1
    simplemole_execution_content_allowed "$candidate" || return 1
    if [[ "$candidate" == *"/CoreSimulator/"* ]]; then
        simplemole_any_process_state Simulator CoreSimulatorService simctl || state=$?
    else
        simplemole_any_process_state \
            Xcode xcodebuild xctest XCTRunner XCBBuildService swift-frontend \
            || state=$?
    fi
    [[ "$state" -eq 1 ]]
}

simplemole_install_delete_final_guard simplemole_xcode_path_guard || {
    echo "error: could not install final Xcode runtime guard"
    exit 1
}

while IFS= read -r -d '' path; do
    identity=""
    if ! IFS= read -r -d '' identity; then
        echo "error: missing identity for Xcode cleanup path: $path"
        failed=$((failed + 1))
        break
    fi
    if [[ -z "$path" || ! "$identity" =~ ^[0-9]+:[0-9]+:[0-9]+$ ]]; then
        failed=$((failed + 1))
        continue
    fi
    # A malformed or redirected path is an integrity failure. A well-formed
    # path outside this bridge's allowlist is merely an unsupported stale row.
    if ! simplemole_xcode_path_is_physical "$path"; then
        failed=$((failed + 1)); continue
    fi
    if ! is_allowed "$path"; then skipped=$((skipped + 1)); continue; fi
    if is_path_whitelisted "$path"; then skipped=$((skipped + 1)); continue; fi
    current_identity=$("$STAT_BSD" -f%d:%i:%m "$path" 2>/dev/null || true)
    [[ "$current_identity" == "$identity" ]] || { failed=$((failed + 1)); continue; }
    # The complete runtime/content guard runs once at mole_delete's final edge.
    if mole_delete "$path" false "$identity"; then removed=$((removed + 1)); else failed=$((failed + 1)); fi
done

printf 'removed=%s\nskipped=%s\nfailed=%s\n' "$removed" "$skipped" "$failed"
[[ "$failed" -eq 0 ]]
