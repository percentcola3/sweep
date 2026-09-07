#!/bin/bash
# Restore hibernated project artifacts from an exact, private receipt.
# All records are preflighted before any move; failures trigger best-effort rollback.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1090
source "$SCRIPT_DIR/app_project_hibernate.sh"

SM_RESTORE_ROOTS=()
SM_RESTORE_ROOT_IDENTITIES=()
SM_RESTORE_ORIGINALS=()
SM_RESTORE_ORIGINAL_IDENTITIES=()
SM_RESTORE_TRASH_PATHS=()
SM_RESTORE_TRASH_IDENTITIES=()
SM_RESTORE_KINDS=()
SM_RESTORE_PARENT_IDENTITIES=()

sm_restore_record_is_duplicate() {
    local original="$1" trash_path="$2" index
    for ((index = 0; index < ${#SM_RESTORE_ORIGINALS[@]}; index++)); do
        [[ "${SM_RESTORE_ORIGINALS[$index]}" == "$original" ||
           "${SM_RESTORE_TRASH_PATHS[$index]}" == "$trash_path" ]] && return 0
    done
    return 1
}

sm_restore_target_valid() {
    local root="$1" original="$2" parent="" parent_physical=""
    sm_project_path_syntax_safe "$original" || return 1
    [[ "$original" == "$root/"* && "$original" != "$root" ]] || return 1
    case "$original" in
        "$root/.git" | "$root/.git/"*) return 1 ;;
    esac
    [[ ! -e "$original" && ! -L "$original" ]] || return 1
    parent="${original%/*}"
    parent_physical=$(sm_project_real_directory "$parent" 2>/dev/null || true)
    [[ -n "$parent_physical" && "$parent_physical" == "$parent" ]] || return 1
    [[ "$parent" == "$root" || "$parent" == "$root/"* ]] || return 1
    sm_hibernation_owned_directory "$parent" || return 1
    [[ -w "$parent" && -x "$parent" ]]
}

sm_restore_parent_identity() {
    local parent="${1%/*}"
    "$STAT_BSD" -f%d:%i "$parent" 2>/dev/null
}

sm_restore_trash_source_valid() {
    local path="$1" identity="$2" original_identity="$3"
    local physical="" parent="" current=""
    [[ "$identity" =~ ^[0-9]+:[0-9]+:[0-9]+$ &&
       "$original_identity" == "$identity" ]] || return 1
    physical=$(sm_project_real_directory "$path" 2>/dev/null || true)
    [[ -n "$physical" && "$physical" == "$path" ]] || return 1
    parent="${path%/*}"
    [[ "$parent" == "$SM_HIBERNATION_TRASH_ROOT" ]] || return 1
    sm_hibernation_owned_directory "$path" || return 1
    current=$(sm_project_file_identity "$path" 2>/dev/null || true)
    [[ "$current" == "$identity" ]]
}

sm_restore_preflight_one() {
    local root="$1" root_identity="$2" original="$3" original_identity="$4"
    local trash_path="$5" trash_identity="$6" kind="$7"
    local source_device="" target_device="" target_parent="${original%/*}"
    [[ "${EUID:-0}" -ne 0 ]] || return 1
    sm_hibernation_kind_allowed "$kind" || return 1
    sm_hibernation_root_valid "$root" "$root_identity" || return 1
    sm_restore_target_valid "$root" "$original" || return 1
    sm_restore_trash_source_valid "$trash_path" "$trash_identity" "$original_identity" || return 1
    sm_restore_record_is_duplicate "$original" "$trash_path" && return 1

    source_device=$("$STAT_BSD" -f%d "$trash_path" 2>/dev/null || true)
    target_device=$("$STAT_BSD" -f%d "$target_parent" 2>/dev/null || true)
    [[ "$source_device" =~ ^[0-9]+$ && "$source_device" == "$target_device" ]] || return 1
    sm_project_activity_check "$root"
    [[ "$SM_PROJECT_ACTIVITY_STATE" == "idle" ]]
}

sm_restore_read_and_preflight() {
    local root root_identity original original_identity trash_path trash_identity kind
    while IFS= read -r -d '' root; do
        IFS= read -r -d '' root_identity || return 1
        IFS= read -r -d '' original || return 1
        IFS= read -r -d '' original_identity || return 1
        IFS= read -r -d '' trash_path || return 1
        IFS= read -r -d '' trash_identity || return 1
        IFS= read -r -d '' kind || return 1
        sm_restore_preflight_one "$root" "$root_identity" "$original" \
            "$original_identity" "$trash_path" "$trash_identity" "$kind" || return 1
        SM_RESTORE_ROOTS+=("$root")
        SM_RESTORE_ROOT_IDENTITIES+=("$root_identity")
        SM_RESTORE_ORIGINALS+=("$original")
        SM_RESTORE_ORIGINAL_IDENTITIES+=("$original_identity")
        SM_RESTORE_TRASH_PATHS+=("$trash_path")
        SM_RESTORE_TRASH_IDENTITIES+=("$trash_identity")
        SM_RESTORE_KINDS+=("$kind")
        SM_RESTORE_PARENT_IDENTITIES+=("$(sm_restore_parent_identity "$original")")
    done
    [[ ${#SM_RESTORE_ORIGINALS[@]} -gt 0 ]]
}

sm_restore_rollback() {
    local last_index="$1" index original trash_path identity
    for ((index = last_index; index >= 0; index--)); do
        original="${SM_RESTORE_ORIGINALS[$index]}"
        trash_path="${SM_RESTORE_TRASH_PATHS[$index]}"
        identity="${SM_RESTORE_TRASH_IDENTITIES[$index]}"
        [[ -d "$original" && ! -e "$trash_path" && ! -L "$trash_path" ]] || continue
        [[ "$(sm_project_file_identity "$original" 2>/dev/null || true)" == "$identity" ]] || continue
        /bin/mv -n "$original" "$trash_path" 2>/dev/null || true
    done
}

sm_project_restore_main() {
    local index moved=-1 original trash_path identity failed=0
    if [[ "${EUID:-0}" -eq 0 ]] || ! sm_hibernation_prepare_trash; then
        sm_project_emit summary 0 1
        return 1
    fi
    if ! sm_restore_read_and_preflight; then
        sm_project_emit summary 0 1
        return 1
    fi

    for ((index = 0; index < ${#SM_RESTORE_ORIGINALS[@]}; index++)); do
        original="${SM_RESTORE_ORIGINALS[$index]}"
        trash_path="${SM_RESTORE_TRASH_PATHS[$index]}"
        identity="${SM_RESTORE_TRASH_IDENTITIES[$index]}"

        # Revalidate the authorization root, exact parent directory, activity,
        # source identity and target absence immediately before the only move.
        if ! sm_hibernation_root_valid "${SM_RESTORE_ROOTS[$index]}" \
                "${SM_RESTORE_ROOT_IDENTITIES[$index]}" ||
           ! sm_restore_target_valid "${SM_RESTORE_ROOTS[$index]}" "$original" ||
           [[ "$(sm_restore_parent_identity "$original" 2>/dev/null || true)" != \
              "${SM_RESTORE_PARENT_IDENTITIES[$index]}" ]] ||
           ! sm_restore_trash_source_valid "$trash_path" "$identity" \
                "${SM_RESTORE_ORIGINAL_IDENTITIES[$index]}"; then
            failed=1
            break
        fi
        sm_project_activity_check "${SM_RESTORE_ROOTS[$index]}"
        if [[ "$SM_PROJECT_ACTIVITY_STATE" != "idle" ]] ||
           ! sm_hibernation_root_valid "${SM_RESTORE_ROOTS[$index]}" \
                "${SM_RESTORE_ROOT_IDENTITIES[$index]}" ||
           ! sm_restore_target_valid "${SM_RESTORE_ROOTS[$index]}" "$original" ||
           [[ "$(sm_restore_parent_identity "$original" 2>/dev/null || true)" != \
              "${SM_RESTORE_PARENT_IDENTITIES[$index]}" ]] ||
           ! sm_restore_trash_source_valid "$trash_path" "$identity" \
                "${SM_RESTORE_ORIGINAL_IDENTITIES[$index]}"; then
            failed=1
            break
        fi
        if ! /bin/mv -n "$trash_path" "$original" 2>/dev/null ||
           [[ -e "$trash_path" || -L "$trash_path" ]] ||
           [[ "$(sm_project_file_identity "$original" 2>/dev/null || true)" != "$identity" ]]; then
            failed=1
            break
        fi
        moved="$index"
    done

    if [[ "$failed" -ne 0 ]]; then
        sm_restore_rollback "$moved"
        sm_project_emit summary 0 1
        return 1
    fi

    for ((index = 0; index < ${#SM_RESTORE_ORIGINALS[@]}; index++)); do
        sm_project_emit restored "${SM_RESTORE_ROOTS[$index]}" \
            "${SM_RESTORE_ORIGINALS[$index]}" "${SM_RESTORE_TRASH_PATHS[$index]}" \
            "${SM_RESTORE_KINDS[$index]}"
    done
    sm_project_emit summary "${#SM_RESTORE_ORIGINALS[@]}" 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    sm_project_restore_main "$@"
fi
