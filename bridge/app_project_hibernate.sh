#!/bin/bash
# Move explicitly selected generated project artifacts to Trash.
# Input and output records are NUL-delimited; no command text is accepted.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1090
source "$SCRIPT_DIR/app_project_activity.sh"
# shellcheck disable=SC1090
source "$SCRIPT_DIR/app_runtime_guard.sh"

SM_HIBERNATION_TRASH_ROOT=""
SM_HIBERNATION_TRASH_PATH=""
SM_HIBERNATION_GUARD_ROOT=""
SM_HIBERNATION_GUARD_ROOT_IDENTITY=""
SM_HIBERNATION_GUARD_MODE=""
SM_HIBERNATION_GUARD_MAX_ACTIVITY="-"
SM_HIBERNATION_GUARD_RISK=""
SM_HIBERNATION_GUARD_KIND=""
SM_HIBERNATION_GUARD_PATH=""
SM_HIBERNATION_GUARD_IDENTITY=""

sm_hibernation_kind_allowed() {
    case "${1:-}" in
        cacheTag|pythonCache|javascriptCache|rustTarget|javaCache|swiftBuild|\
        dartCache|zigCache|nativeBuildCache|coverage|dependencyNodeModules|\
        dependencyPods|dependencyComposer|dependencyVirtualEnv|genericBuildOutput)
            return 0
            ;;
    esac
    return 1
}

sm_hibernation_owned_directory() {
    local path="$1" owner=""
    [[ -d "$path" && ! -L "$path" ]] || return 1
    owner=$("$STAT_BSD" -f%u "$path" 2>/dev/null || true)
    [[ "$owner" == "${EUID:-}" ]]
}

sm_hibernation_root_valid() {
    local root="$1" expected_identity="$2" physical="" current=""
    [[ "$expected_identity" =~ ^[0-9]+:[0-9]+$ ]] || return 1
    physical=$(sm_project_real_directory "$root" 2>/dev/null || true)
    [[ -n "$physical" && "$physical" == "$root" ]] || return 1
    sm_project_is_root "$root" || return 1
    sm_hibernation_owned_directory "$root" || return 1
    current=$(sm_project_root_identity "$root" 2>/dev/null || true)
    [[ "$current" == "$expected_identity" ]]
}

sm_hibernation_artifact_path_valid() {
    local path="$1" root="$2" physical="" parent="" parent_physical=""
    sm_project_path_syntax_safe "$path" || return 1
    [[ "$path" == "$root/"* && "$path" != "$root" ]] || return 1
    case "$path" in
        "$root/.git" | "$root/.git/"*) return 1 ;;
    esac
    physical=$(sm_project_real_directory "$path" 2>/dev/null || true)
    [[ -n "$physical" && "$physical" == "$path" ]] || return 1
    parent="${path%/*}"
    parent_physical=$(sm_project_real_directory "$parent" 2>/dev/null || true)
    [[ -n "$parent_physical" && "$parent_physical" == "$parent" ]] || return 1
    [[ "$parent" == "$root" || "$parent" == "$root/"* ]] || return 1
    sm_hibernation_owned_directory "$path" || return 1
    sm_hibernation_owned_directory "$parent" || return 1
    [[ -w "$parent" && -x "$parent" ]] || return 1

    local path_device="" parent_device=""
    path_device=$("$STAT_BSD" -f%d "$path" 2>/dev/null || true)
    parent_device=$("$STAT_BSD" -f%d "$parent" 2>/dev/null || true)
    [[ "$path_device" =~ ^[0-9]+$ && "$path_device" == "$parent_device" ]]
}

sm_hibernation_prepare_trash() {
    local candidate="" home_physical="" physical="" owner=""
    if [[ "${MOLE_TEST_MODE:-0}" == "1" && -n "${MOLE_TEST_TRASH_DIR:-}" ]]; then
        candidate="$MOLE_TEST_TRASH_DIR"
    else
        unset MOLE_TEST_TRASH_DIR
        home_physical=$(sm_project_real_directory "${HOME:-}" 2>/dev/null || true)
        [[ -n "$home_physical" && "$home_physical" == "${HOME:-}" ]] || return 1
        candidate="$home_physical/.Trash"
    fi
    sm_project_path_syntax_safe "$candidate" || return 1
    [[ ! -L "$candidate" ]] || return 1
    if [[ ! -d "$candidate" ]]; then
        /bin/mkdir -p "$candidate" 2>/dev/null || return 1
        /bin/chmod 700 "$candidate" 2>/dev/null || return 1
    fi
    physical=$(sm_project_real_directory "$candidate" 2>/dev/null || true)
    [[ -n "$physical" && "$physical" == "$candidate" ]] || return 1
    owner=$("$STAT_BSD" -f%u "$physical" 2>/dev/null || true)
    [[ "$owner" == "${EUID:-}" && -w "$physical" && -x "$physical" ]] || return 1
    SM_HIBERNATION_TRASH_ROOT="$physical"
}

sm_hibernation_trash_accepts() {
    local path="$1" path_device="" trash_device=""
    [[ -n "$SM_HIBERNATION_TRASH_ROOT" ]] || return 1
    path_device=$("$STAT_BSD" -f%d "$path" 2>/dev/null || true)
    trash_device=$("$STAT_BSD" -f%d "$SM_HIBERNATION_TRASH_ROOT" 2>/dev/null || true)
    [[ "$path_device" =~ ^[0-9]+$ && "$path_device" == "$trash_device" ]]
}

sm_hibernation_find_trash_path() {
    local expected_identity="$1" candidate="" current=""
    SM_HIBERNATION_TRASH_PATH=""
    while IFS= read -r -d '' candidate; do
        current=$(sm_project_file_identity "$candidate" 2>/dev/null || true)
        if [[ "$current" == "$expected_identity" ]]; then
            SM_HIBERNATION_TRASH_PATH="$candidate"
            return 0
        fi
    done < <(command find "$SM_HIBERNATION_TRASH_ROOT" -mindepth 1 -maxdepth 1 \
        -type d -print0 2>/dev/null || true)
    return 1
}

sm_hibernation_recently_modified() {
    local path="$1" latest="" now=""
    latest=$(sm_project_artifact_mtime "$path" 2>/dev/null || true)
    now=$(/bin/date +%s 2>/dev/null || true)
    [[ "$latest" =~ ^[0-9]+$ && "$latest" -gt 0 && "$now" =~ ^[0-9]+$ ]] || return 0
    [[ "$latest" -gt "$now" || $((now - latest)) -lt 3600 ]]
}

sm_hibernation_activity_within_cutoff() {
    local root="$1" cutoff="$2" latest=""
    [[ "$cutoff" == "-" ]] && return 0
    [[ "$cutoff" =~ ^[0-9]+$ ]] || return 1
    latest=$(sm_project_latest_activity "$root" 2>/dev/null || true)
    [[ "$latest" =~ ^[0-9]+$ && "$latest" -le "$cutoff" ]]
}

# This guard runs inside Mole's Trash helper, after its size and identity work
# and immediately before the recoverable filesystem mutation.
sm_hibernation_final_guard() {
    local candidate="${1:-}" current_identity="" content_state=0
    [[ -n "$SM_HIBERNATION_GUARD_ROOT" &&
       -n "$SM_HIBERNATION_GUARD_ROOT_IDENTITY" &&
       -n "$SM_HIBERNATION_GUARD_PATH" &&
       -n "$SM_HIBERNATION_GUARD_IDENTITY" &&
       "$candidate" == "$SM_HIBERNATION_GUARD_PATH" ]] || return 1
    load_mole_whitelist
    is_path_whitelisted "$candidate" && return 1
    sm_hibernation_root_valid "$SM_HIBERNATION_GUARD_ROOT" \
        "$SM_HIBERNATION_GUARD_ROOT_IDENTITY" || return 1
    sm_hibernation_artifact_path_valid "$candidate" \
        "$SM_HIBERNATION_GUARD_ROOT" || return 1
    current_identity=$(sm_project_file_identity "$candidate" 2>/dev/null || true)
    [[ "$current_identity" == "$SM_HIBERNATION_GUARD_IDENTITY" ]] || return 1

    sm_project_classify_artifact "$candidate" "$SM_HIBERNATION_GUARD_ROOT"
    [[ "$SM_ARTIFACT_RISK" == "$SM_HIBERNATION_GUARD_RISK" &&
       "$SM_ARTIFACT_KIND" == "$SM_HIBERNATION_GUARD_KIND" ]] || return 1
    if [[ "$SM_HIBERNATION_GUARD_MODE" == "automatic" ]]; then
        [[ "$SM_ARTIFACT_RISK" == "safe" ]] || return 1
        simplemole_automatic_content_state "$candidate" || content_state=$?
        [[ "$content_state" -eq 1 ]] || return 1
        sm_hibernation_recently_modified "$candidate" && return 1
        sm_hibernation_activity_within_cutoff "$SM_HIBERNATION_GUARD_ROOT" \
            "$SM_HIBERNATION_GUARD_MAX_ACTIVITY" || return 1
    elif [[ "$SM_HIBERNATION_GUARD_MODE" == "manual" ]]; then
        [[ "$SM_HIBERNATION_GUARD_MAX_ACTIVITY" == "-" &&
           ( "$SM_ARTIFACT_RISK" == "safe" || "$SM_ARTIFACT_RISK" == "warning" ) ]] || return 1
    else
        return 1
    fi

    sm_project_activity_check "$SM_HIBERNATION_GUARD_ROOT"
    [[ "$SM_PROJECT_ACTIVITY_STATE" == "idle" ]] || return 1
    sm_hibernation_trash_accepts "$candidate"
}

sm_hibernation_measure_bytes() {
    local path="$1" blocks=""
    blocks=$(/usr/bin/du -sk "$path" 2>/dev/null | /usr/bin/awk '{print $1; exit}') || return 1
    [[ "$blocks" =~ ^[0-9]+$ ]] || return 1
    printf '%s\n' "$((blocks * 1024))"
}

sm_hibernation_emit_unavailable() {
    local root="$1" path="$2" identity="$3" kind="$4" bytes="${5:-0}"
    sm_hibernation_kind_allowed "$kind" || kind="unknown"
    [[ "$bytes" =~ ^[0-9]+$ ]] || bytes=0
    sm_project_emit unavailable "$root" "$path" "$identity" "$bytes" "$kind"
}

sm_hibernation_apply_one() {
    local root="$1" root_identity="$2" mode="$3" maximum_activity="$4"
    local expected_risk="$5" expected_kind="$6" path="$7" expected_identity="$8"
    local current_identity="" bytes="" trash_identity="" content_state=0

    [[ "${EUID:-0}" -ne 0 ]] || return 1
    case "$mode" in automatic|manual) ;; *) return 1 ;; esac
    [[ "$maximum_activity" == "-" || "$maximum_activity" =~ ^[0-9]+$ ]] || return 1
    [[ "$mode" != "manual" || "$maximum_activity" == "-" ]] || return 1
    case "$expected_risk" in safe|warning) ;; *) return 1 ;; esac
    sm_hibernation_kind_allowed "$expected_kind" || return 1
    sm_hibernation_root_valid "$root" "$root_identity" || return 1
    sm_hibernation_artifact_path_valid "$path" "$root" || return 1
    [[ "$expected_identity" =~ ^[0-9]+:[0-9]+:[0-9]+$ ]] || return 1
    current_identity=$(sm_project_file_identity "$path" 2>/dev/null || true)
    [[ "$current_identity" == "$expected_identity" ]] || return 1

    sm_project_classify_artifact "$path" "$root"
    [[ "$SM_ARTIFACT_RISK" == "$expected_risk" &&
       "$SM_ARTIFACT_KIND" == "$expected_kind" ]] || return 1
    if [[ "$mode" == "automatic" ]]; then
        [[ "$SM_ARTIFACT_RISK" == "safe" ]] || return 1
        simplemole_automatic_content_state "$path" || content_state=$?
        [[ "$content_state" -eq 1 ]] || return 1
        sm_hibernation_recently_modified "$path" && return 1
        sm_hibernation_activity_within_cutoff "$root" "$maximum_activity" || return 1
    else
        [[ "$SM_ARTIFACT_RISK" == "safe" || "$SM_ARTIFACT_RISK" == "warning" ]] || return 1
    fi

    sm_project_activity_check "$root"
    [[ "$SM_PROJECT_ACTIVITY_STATE" == "idle" ]] || return 1
    sm_hibernation_trash_accepts "$path" || return 1
    bytes=$(sm_hibernation_measure_bytes "$path") || return 1

    # Rebind identity and activity immediately before the only mutation.
    current_identity=$(sm_project_file_identity "$path" 2>/dev/null || true)
    [[ "$current_identity" == "$expected_identity" ]] || return 1
    sm_hibernation_root_valid "$root" "$root_identity" || return 1
    if [[ "$mode" == "automatic" ]]; then
        sm_hibernation_activity_within_cutoff "$root" "$maximum_activity" || return 1
    fi
    sm_project_activity_check "$root"
    [[ "$SM_PROJECT_ACTIVITY_STATE" == "idle" ]] || return 1

    SM_HIBERNATION_GUARD_ROOT="$root"
    SM_HIBERNATION_GUARD_ROOT_IDENTITY="$root_identity"
    SM_HIBERNATION_GUARD_MODE="$mode"
    SM_HIBERNATION_GUARD_MAX_ACTIVITY="$maximum_activity"
    SM_HIBERNATION_GUARD_RISK="$expected_risk"
    SM_HIBERNATION_GUARD_KIND="$expected_kind"
    SM_HIBERNATION_GUARD_PATH="$path"
    SM_HIBERNATION_GUARD_IDENTITY="$expected_identity"
    if ! mole_delete "$path" false "$expected_identity"; then return 1; fi
    [[ ! -e "$path" && ! -L "$path" ]] || return 1

    sm_hibernation_find_trash_path "$expected_identity" || return 1
    trash_identity=$(sm_project_file_identity "$SM_HIBERNATION_TRASH_PATH" 2>/dev/null || true)
    [[ "$trash_identity" == "$expected_identity" ]] || return 1
    sm_project_emit trashed "$root" "$path" "$expected_identity" \
        "$SM_HIBERNATION_TRASH_PATH" "$trash_identity" "$bytes" "$expected_kind"
}

sm_project_hibernate_main() {
    load_mole_whitelist
    export MOLE_CURRENT_COMMAND="project-hibernate" MOLE_DELETE_MODE="trash"
    local root root_identity mode maximum_activity expected_risk expected_kind path expected_identity
    local removed=0 failed=0 bytes=0

    if ! sm_hibernation_prepare_trash ||
       ! simplemole_install_trash_final_guard sm_hibernation_final_guard; then
        sm_project_emit summary 0 1
        return 1
    fi

    while IFS= read -r -d '' root; do
        if ! IFS= read -r -d '' root_identity ||
           ! IFS= read -r -d '' mode ||
           ! IFS= read -r -d '' maximum_activity ||
           ! IFS= read -r -d '' expected_risk ||
           ! IFS= read -r -d '' expected_kind ||
           ! IFS= read -r -d '' path ||
           ! IFS= read -r -d '' expected_identity; then
            failed=$((failed + 1))
            break
        fi
        bytes=$(sm_hibernation_measure_bytes "$path" 2>/dev/null || true)
        [[ "$bytes" =~ ^[0-9]+$ ]] || bytes=0
        if sm_hibernation_apply_one "$root" "$root_identity" "$mode" \
            "$maximum_activity" "$expected_risk" "$expected_kind" \
            "$path" "$expected_identity"; then
            removed=$((removed + 1))
        else
            sm_hibernation_emit_unavailable "$root" "$path" "$expected_identity" \
                "$expected_kind" "$bytes"
            failed=$((failed + 1))
        fi
    done
    sm_project_emit summary "$removed" "$failed"
    [[ "$failed" -eq 0 ]]
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    sm_project_hibernate_main "$@"
fi
