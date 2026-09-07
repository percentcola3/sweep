#!/bin/bash
# Fail-closed runtime activity check for project roots.
# Input roots and output records are NUL-delimited.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1090
source "$SCRIPT_DIR/app_project_radar.sh"
source "$SCRIPT_DIR/app_scan_access.sh"

SM_PROJECT_ACTIVITY_STATE="unknown"
SM_PROJECT_ACTIVITY_REASON="not-checked"
SM_PROJECT_LSOF_SNAPSHOT_STATE="unprepared"
SM_PROJECT_LSOF_SNAPSHOT_FILE=""
SM_PROJECT_LSOF_SNAPSHOT_REASON="not-checked"

sm_project_activity_lsof_bin() {
    if [[ "${MOLE_TEST_MODE:-0}" == "1" && -n "${SM_LSOF_BIN:-}" ]]; then
        [[ "$SM_LSOF_BIN" == /* && -x "$SM_LSOF_BIN" ]] || return 1
        printf '%s\n' "$SM_LSOF_BIN"
        return 0
    fi
    [[ -x /usr/sbin/lsof ]] || return 1
    printf '%s\n' /usr/sbin/lsof
}

sm_project_activity_has_git_operation() {
    local root="$1"
    [[ -e "$root/.git/index.lock" || -e "$root/.git/MERGE_HEAD" ||
       -d "$root/.git/rebase-apply" || -d "$root/.git/rebase-merge" ]]
}

sm_project_activity_prepare_lsof_snapshot() {
    local lsof_bin="" error_file="" status=0
    [[ "$SM_PROJECT_LSOF_SNAPSHOT_STATE" == "unprepared" ]] || {
        [[ "$SM_PROJECT_LSOF_SNAPSHOT_STATE" == "ready" ]]
        return
    }
    SM_PROJECT_LSOF_SNAPSHOT_STATE="unavailable"
    SM_PROJECT_LSOF_SNAPSHOT_REASON="lsof-unavailable"
    lsof_bin=$(sm_project_activity_lsof_bin 2>/dev/null || true)
    [[ -n "$lsof_bin" ]] || return 2

    SM_PROJECT_LSOF_SNAPSHOT_FILE=$(create_temp_file 2>/dev/null || true)
    error_file=$(create_temp_file 2>/dev/null || true)
    if [[ -z "$SM_PROJECT_LSOF_SNAPSHOT_FILE" ||
          ! -f "$SM_PROJECT_LSOF_SNAPSHOT_FILE" ||
          -L "$SM_PROJECT_LSOF_SNAPSHOT_FILE" ||
          -z "$error_file" || ! -f "$error_file" || -L "$error_file" ]]; then
        SM_PROJECT_LSOF_SNAPSHOT_REASON="temporary-file"
        return 2
    fi
    run_with_timeout 10 "$lsof_bin" -nP -Fpn \
        > "$SM_PROJECT_LSOF_SNAPSHOT_FILE" 2> "$error_file" || status=$?
    if [[ "$status" -eq 124 || "$status" -ge 128 ]]; then
        SM_PROJECT_LSOF_SNAPSHOT_REASON="lsof-timeout"
        return 2
    fi
    if [[ -s "$error_file" || ( "$status" -ne 0 && "$status" -ne 1 ) ]]; then
        SM_PROJECT_LSOF_SNAPSHOT_REASON="lsof-error"
        return 2
    fi
    if [[ "$status" -eq 0 && -s "$SM_PROJECT_LSOF_SNAPSHOT_FILE" ]]; then
        SM_PROJECT_LSOF_SNAPSHOT_STATE="ready"
        SM_PROJECT_LSOF_SNAPSHOT_REASON="complete"
        return 0
    fi
    if [[ "$status" -eq 1 && ! -s "$SM_PROJECT_LSOF_SNAPSHOT_FILE" ]]; then
        SM_PROJECT_LSOF_SNAPSHOT_STATE="ready"
        SM_PROJECT_LSOF_SNAPSHOT_REASON="empty"
        return 0
    fi
    SM_PROJECT_LSOF_SNAPSHOT_REASON="unbound-lsof-output"
    return 2
}

# Sets SM_PROJECT_ACTIVITY_STATE to idle, active, or unknown. "unknown" is
# deliberately not treated as idle by any automated caller.
sm_project_activity_check() {
    local root="${1:-}"
    SM_PROJECT_ACTIVITY_STATE="unknown"
    SM_PROJECT_ACTIVITY_REASON="permission-required"

    # Mutation workflows such as hibernation deliberately request a fresh
    # snapshot at each edge. Inventory and purge batches can opt into one
    # shared read-only snapshot for all roots in that short-lived process.
    if [[ "${SM_PROJECT_ACTIVITY_REUSE_SNAPSHOT:-0}" != "1" ]]; then
        SM_PROJECT_LSOF_SNAPSHOT_STATE="unprepared"
        SM_PROJECT_LSOF_SNAPSHOT_FILE=""
        SM_PROJECT_LSOF_SNAPSHOT_REASON="not-checked"
    fi

    forgesweep_scan_path_allowed "$root" || return 0
    SM_PROJECT_ACTIVITY_REASON="invalid-project"

    local physical=""
    physical=$(sm_project_real_directory "$root" 2>/dev/null || true)
    [[ -n "$physical" && "$physical" == "$root" ]] || return 0
    sm_project_is_root "$physical" || return 0

    if sm_project_activity_has_git_operation "$physical"; then
        SM_PROJECT_ACTIVITY_STATE="active"
        SM_PROJECT_ACTIVITY_REASON="git-operation"
        return 0
    fi

    local line="" saw_name=false
    if ! sm_project_activity_prepare_lsof_snapshot; then
        SM_PROJECT_ACTIVITY_REASON="$SM_PROJECT_LSOF_SNAPSHOT_REASON"
        return 0
    fi

    while IFS= read -r line; do
        case "$line" in
            n"$physical" | n"$physical/"*)
                saw_name=true
                SM_PROJECT_ACTIVITY_STATE="active"
                SM_PROJECT_ACTIVITY_REASON="open-file"
                return 0
                ;;
            n*) saw_name=true ;;
        esac
    done < "$SM_PROJECT_LSOF_SNAPSHOT_FILE"

    if [[ "$saw_name" == "true" ||
          "$SM_PROJECT_LSOF_SNAPSHOT_REASON" == "empty" ]]; then
        SM_PROJECT_ACTIVITY_STATE="idle"
        SM_PROJECT_ACTIVITY_REASON="no-open-file"
    else
        # A successful-looking but malformed/partial snapshot is not proof that
        # the project is idle.
        SM_PROJECT_ACTIVITY_REASON="unbound-lsof-output"
    fi
}

sm_project_activity_main() {
    local raw root checked=0 active=0 unknown=0
    while IFS= read -r -d '' raw; do
        if ! forgesweep_scan_path_allowed "$raw"; then
            sm_project_emit activity "$raw" unknown permission-required
            unknown=$((unknown + 1))
            continue
        fi
        root=$(sm_project_real_directory "$raw" 2>/dev/null || true)
        if [[ -z "$root" ]]; then
            sm_project_emit activity "$raw" unknown invalid-project
            unknown=$((unknown + 1))
            continue
        fi
        sm_project_activity_check "$root"
        sm_project_emit activity "$root" "$SM_PROJECT_ACTIVITY_STATE" \
            "$SM_PROJECT_ACTIVITY_REASON"
        checked=$((checked + 1))
        [[ "$SM_PROJECT_ACTIVITY_STATE" == "active" ]] && active=$((active + 1))
        [[ "$SM_PROJECT_ACTIVITY_STATE" == "unknown" ]] && unknown=$((unknown + 1))
    done
    sm_project_emit summary "$checked" "$active" "$unknown"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    sm_project_activity_main "$@"
fi
