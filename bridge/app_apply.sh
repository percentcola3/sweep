#!/bin/bash
# App bridge: apply an explicit, user-reviewed cleanup plan.
# Records arrive as NUL-delimited path/identity pairs. The identity is captured
# when the user confirms and is rechecked by mole_delete at the final sink.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/core/common.sh"
# shellcheck disable=SC1090
source "$SCRIPT_DIR/bin/app_nvm_guard.sh"
# shellcheck disable=SC1090
source "$SCRIPT_DIR/bin/app_runtime_guard.sh"
# Keep the generic cleanup bridge on the same user-home/physical-path boundary
# as the specialized routes. The UI only submits Safe cache/Trash rows, but a
# hand-crafted stdin plan must not turn this reusable sink into an arbitrary
# /Users or /tmp deletion primitive.
# shellcheck disable=SC1090
source "$SCRIPT_DIR/bin/app_scan_access.sh"

export MOLE_CURRENT_COMMAND="clean"
simplemole_configure_delete_mode
load_mole_whitelist

removed=0
skipped=0
failed=0

simplemole_generic_cache_guard() {
    local candidate="$1" owner="" state=0 content_state=0
    if [[ "${MOLE_TEST_MODE:-0}" == "1" && -n "${SIMPLEMOLE_TEST_FINAL_GUARD_LOG:-}" ]]; then
        printf 'generic\n' >> "$SIMPLEMOLE_TEST_FINAL_GUARD_LOG"
    fi
    forgesweep_scan_path_is_physical "$candidate" || return 1
    load_mole_whitelist
    is_path_whitelisted "$candidate" && return 1
    if simplemole_is_home_trash_item "$candidate"; then
        simplemole_trash_content_state "$candidate" || content_state=$?
        [[ "$content_state" -eq 1 ]] || return 1
    elif [[ "$candidate" == "$HOME/.Trash/"* ]]; then
        # Only top-level, aged Trash candidates are authorized by the scanner.
        return 1
    else
        case "${SIMPLEMOLE_EXECUTION_MODE:-manual}" in
            quickClean|automatic|manual)
                # A cache may still contain a nested model/session directory.
                # Keep the content boundary for Quick Clean and permanent
                # disk-clean plans. Recoverable manual Trash routes may still
                # include explicitly reviewed Warning data.
                if [[ "${SIMPLEMOLE_EXECUTION_MODE:-manual}" != "manual" ||
                      "${SIMPLEMOLE_DELETE_MODE:-trash}" == "permanent" ]]; then
                    simplemole_automatic_content_state "$candidate" || content_state=$?
                    [[ "$content_state" -eq 1 ]] || return 1
                fi
                ;;
        esac
    fi
    if owner=$(simplemole_reverse_dns_cache_owner "$candidate"); then
        simplemole_bundle_identifier_state "$owner" || state=$?
    else
        simplemole_path_open_state "$candidate" || state=$?
    fi
    [[ "$state" -eq 1 ]]
}

# Re-run the owner probe after mole_delete's size and identity work, at the
# recoverable mutation edge.
simplemole_install_delete_final_guard simplemole_generic_cache_guard || {
    echo "error: could not install final cleanup runtime guard"
    exit 1
}

# These installations are owned by their version managers. Direct filesystem
# deletion can remove a current/default version after preview, so old plans and
# callers that bypass the current scanner must fail closed at the final sink.
is_owner_managed_runtime_path() {
    local path="$1" physical_path="" root physical_root=""
    physical_path=$(cd -P "$path" 2>/dev/null && pwd) || physical_path=""

    for root in \
        "$HOME/Library/Application Support/fnm/node-versions" \
        "$HOME/.volta/tools/image/node" \
        "$HOME/.asdf/installs/node" \
        "$HOME/.pyenv/versions" \
        "$HOME/.rbenv/versions" \
        "$HOME/.rustup/toolchains"; do
        case "$path" in "$root"|"$root"/*) return 0 ;; esac
        physical_root=$(cd -P "$root" 2>/dev/null && pwd) || physical_root=""
        if [[ -n "$physical_path" && -n "$physical_root" ]]; then
            case "$physical_path" in "$physical_root"|"$physical_root"/*) return 0 ;; esac
        fi
    done
    return 1
}

while IFS= read -r -d '' path; do
    identity=""
    if ! IFS= read -r -d '' identity; then
        echo "error: missing identity for cleanup path: $path"
        failed=$((failed + 1))
        break
    fi
    if [[ -z "$path" ]]; then
        echo "error: empty cleanup path"
        failed=$((failed + 1))
        continue
    fi
    if [[ ! "$identity" =~ ^[0-9]+:[0-9]+:[0-9]+$ ]]; then
        echo "error: invalid or unavailable identity for cleanup path: $path"
        failed=$((failed + 1))
        continue
    fi
    if is_owner_managed_runtime_path "$path"; then
        echo "error: refusing version-manager-owned runtime path; use its owner command: $path"
        failed=$((failed + 1))
        continue
    fi
    if is_path_whitelisted "$path"; then
        skipped=$((skipped + 1))
        continue
    fi
    if ! simplemole_nvm_path_safe_to_delete "$path"; then
        echo "error: refusing current or unresolved nvm version: $path"
        failed=$((failed + 1))
        continue
    fi
    # Runtime/content policy is intentionally checked only by mole_delete's
    # final guard below. Running it here as well doubled recursive scans and
    # lsof/LaunchServices probes without strengthening the mutation edge.
    if mole_delete "$path" false "$identity"; then
        removed=$((removed + 1))
    else
        failed=$((failed + 1))
    fi
done

printf 'removed=%s\nskipped=%s\nfailed=%s\n' "$removed" "$skipped" "$failed"
[[ "$failed" -eq 0 ]]
