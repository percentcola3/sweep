#!/bin/bash
# NUL-delimited path/identity pairs are bound at confirmation time.
set -euo pipefail

APP_ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$APP_ROOT_DIR/lib/core/common.sh"
source "$APP_ROOT_DIR/lib/clean/project.sh"
# shellcheck disable=SC1090
source "$APP_ROOT_DIR/bin/app_project_activity.sh"
# shellcheck disable=SC1090
source "$APP_ROOT_DIR/bin/app_runtime_guard.sh"
load_mole_whitelist
export MOLE_CURRENT_COMMAND="purge"
export SM_PROJECT_ACTIVITY_REUSE_SNAPSHOT=1
simplemole_configure_delete_mode

removed=0
failed=0
SM_PURGE_GUARD_PATH=""
SM_PURGE_GUARD_IDENTITY=""
SM_PURGE_GUARD_ROOT=""
SM_PURGE_GUARD_ROOT_IDENTITY=""
SM_PURGE_GUARD_RISK=""
SM_PURGE_GUARD_KIND=""
SM_PURGE_GUARD_MODE=""

sm_purge_mode_allows() {
    local mode="$1" risk="$2"
    case "$mode" in
        quickClean|automatic) [[ "$risk" == "safe" ]] ;;
        manual) [[ "$risk" == "safe" || "$risk" == "warning" ]] ;;
        *) return 1 ;;
    esac
}

sm_purge_resolve_project() {
    local path="$1" root=""
    root=$(find_purge_project_root_for_artifact "$path" 2>/dev/null || true)
    sm_project_real_directory "$root" 2>/dev/null
}

sm_purge_final_guard() {
    local candidate="${1:-}" current_identity="" root=""
    [[ "$candidate" == "$SM_PURGE_GUARD_PATH" &&
       -n "$SM_PURGE_GUARD_IDENTITY" && -n "$SM_PURGE_GUARD_ROOT" ]] || return 1
    load_mole_whitelist
    is_path_whitelisted "$candidate" && return 1
    is_safe_configured_purge_artifact "$candidate" || return 1
    is_protected_purge_artifact "$candidate" && return 1
    current_identity=$("$STAT_BSD" -f%d:%i:%m "$candidate" 2>/dev/null || true)
    [[ "$current_identity" == "$SM_PURGE_GUARD_IDENTITY" ]] || return 1
    root=$(sm_purge_resolve_project "$candidate" || true)
    [[ "$root" == "$SM_PURGE_GUARD_ROOT" &&
       "$(sm_project_root_identity "$root" 2>/dev/null || true)" == \
       "$SM_PURGE_GUARD_ROOT_IDENTITY" ]] || return 1
    sm_project_classify_artifact "$candidate" "$root"
    [[ "$SM_ARTIFACT_RISK" == "$SM_PURGE_GUARD_RISK" &&
       "$SM_ARTIFACT_KIND" == "$SM_PURGE_GUARD_KIND" ]] || return 1
    sm_purge_mode_allows "$SM_PURGE_GUARD_MODE" "$SM_ARTIFACT_RISK" || return 1
    sm_project_activity_check "$root"
    [[ "$SM_PROJECT_ACTIVITY_STATE" == "idle" ]]
}

execution_mode="${SIMPLEMOLE_EXECUTION_MODE:-manual}"
case "$execution_mode" in manual|quickClean|automatic) ;; *) execution_mode="invalid" ;; esac
simplemole_install_delete_final_guard sm_purge_final_guard || {
    printf 'removed=0\nfailed=1\n'
    exit 1
}

while IFS= read -r -d '' path; do
    identity=""
    if ! IFS= read -r -d '' identity; then
        echo "error: missing identity for purge path: $path"
        failed=$((failed + 1))
        break
    fi
    if [[ -z "$path" || ! "$identity" =~ ^[0-9]+:[0-9]+:[0-9]+$ ]]; then
        failed=$((failed + 1))
        continue
    fi
    is_safe_configured_purge_artifact "$path" || { failed=$((failed + 1)); continue; }
    is_protected_purge_artifact "$path" && { failed=$((failed + 1)); continue; }
    current_identity=$("$STAT_BSD" -f%d:%i:%m "$path" 2>/dev/null || true)
    [[ "$current_identity" == "$identity" ]] || { failed=$((failed + 1)); continue; }
    project_root=$(sm_purge_resolve_project "$path" || true)
    [[ -n "$project_root" && "$path" == "$project_root/"* ]] || {
        failed=$((failed + 1)); continue;
    }
    root_identity=$(sm_project_root_identity "$project_root" 2>/dev/null || true)
    [[ "$root_identity" =~ ^[0-9]+:[0-9]+$ ]] || {
        failed=$((failed + 1)); continue;
    }
    sm_project_classify_artifact "$path" "$project_root"
    [[ "$SM_ARTIFACT_KIND" != "unknown" ]] || { failed=$((failed + 1)); continue; }
    sm_purge_mode_allows "$execution_mode" "$SM_ARTIFACT_RISK" || {
        failed=$((failed + 1)); continue;
    }
    SM_PURGE_GUARD_PATH="$path"
    SM_PURGE_GUARD_IDENTITY="$identity"
    SM_PURGE_GUARD_ROOT="$project_root"
    SM_PURGE_GUARD_ROOT_IDENTITY="$root_identity"
    SM_PURGE_GUARD_RISK="$SM_ARTIFACT_RISK"
    SM_PURGE_GUARD_KIND="$SM_ARTIFACT_KIND"
    SM_PURGE_GUARD_MODE="$execution_mode"
    # Project activity is checked only by sm_purge_final_guard, immediately
    # before the deletion sink. A second preflight lsof snapshot was both stale
    # by mutation time and disproportionately expensive for tiny artifacts.
    if mole_delete "$path" false "$identity"; then removed=$((removed + 1)); else failed=$((failed + 1)); fi
done

printf 'removed=%s\nfailed=%s\n' "$removed" "$failed"
[[ "$failed" -eq 0 ]]
