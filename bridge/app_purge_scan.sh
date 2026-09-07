#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/core/common.sh"
source "$SCRIPT_DIR/../lib/clean/project.sh"
# shellcheck disable=SC1090
source "$SCRIPT_DIR/app_project_activity.sh"
source "$SCRIPT_DIR/app_scan_access.sh"
load_mole_whitelist
export SM_PROJECT_ACTIVITY_REUSE_SNAPSHOT=1

declare -a SM_PURGE_ACTIVITY_ROOTS=()
declare -a SM_PURGE_ACTIVITY_STATES=()
SM_PURGE_ACTIVITY_RESULT="unknown"

sm_purge_capture_activity() {
    local root="$1" index=0
    if [[ ${#SM_PURGE_ACTIVITY_ROOTS[@]} -gt 0 ]]; then
        for ((index = 0; index < ${#SM_PURGE_ACTIVITY_ROOTS[@]}; index++)); do
            if [[ "${SM_PURGE_ACTIVITY_ROOTS[$index]}" == "$root" ]]; then
                SM_PURGE_ACTIVITY_RESULT="${SM_PURGE_ACTIVITY_STATES[$index]}"
                return 0
            fi
        done
    fi
    sm_project_activity_check "$root"
    SM_PURGE_ACTIVITY_RESULT="$SM_PROJECT_ACTIVITY_STATE"
    SM_PURGE_ACTIVITY_ROOTS+=("$root")
    SM_PURGE_ACTIVITY_STATES+=("$SM_PURGE_ACTIVITY_RESULT")
}

stats_dir="${XDG_CACHE_HOME:-$HOME/.cache}/mole"
if ! mkdir -p "$stats_dir" 2>/dev/null; then
    stats_dir="$(mktemp -d "${TMPDIR:-/tmp}/mole-purge-state.XXXXXX")"
fi
if ! touch "$stats_dir/purge_scanning" 2>/dev/null; then
    stats_dir="$(mktemp -d "${TMPDIR:-/tmp}/mole-purge-state.XXXXXX")"
    touch "$stats_dir/purge_scanning"
fi
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/mole-app-purge.XXXXXX")"
trap 'rm -rf "$tmp_dir"; rm -f "$stats_dir/purge_scanning"' EXIT

# `scan_purge_targets` already bounds the workers inside one root (fd uses its
# own thread pool), but the bridge used to run every configured root in series.
# A small root pool removes that idle gap without allowing the nested walkers to
# fan out indefinitely. Keep the default at two roots: two fd pools of eight
# threads are enough to hide disk latency on a laptop without saturating it.
max_scan_jobs="${SM_PURGE_MAX_SCAN_JOBS:-2}"
if ! [[ "$max_scan_jobs" =~ ^[0-9]+$ ]]; then
    max_scan_jobs=2
else
    # Force decimal arithmetic so values such as "08" do not trip Bash 3.2's
    # octal parser. Overflowed/negative values are treated as invalid below.
    max_scan_jobs=$((10#$max_scan_jobs))
    if (( max_scan_jobs < 1 )); then
        max_scan_jobs=2
    elif (( max_scan_jobs > 4 )); then
        max_scan_jobs=4
    fi
fi

declare -a scan_roots=()
declare -a scan_outputs=()
declare -a scan_pids=()
declare -a scan_statuses=()
declare -a pending_scan_indices=()

wait_scan_batch() {
    local index pid scan_status
    for index in "${pending_scan_indices[@]+"${pending_scan_indices[@]}"}"; do
        pid="${scan_pids[$index]:-}"
        scan_status=0
        if [[ "$pid" =~ ^[0-9]+$ ]]; then
            wait "$pid" || scan_status=$?
        else
            scan_status=1
        fi
        scan_statuses[$index]="$scan_status"
    done
    pending_scan_indices=()
}

# Start all root scans in bounded batches. Only the read-only discovery phase is
# concurrent; result validation and activity classification remain serial below,
# preserving the original ordering and all dynamic-scope guard semantics.
for root in "${PURGE_SEARCH_PATHS[@]}"; do
    forgesweep_scan_path_allowed "$root" || continue
    [[ -d "$root" ]] || continue

    # Each output is private to this invocation. An ordinal avoids a hash
    # process per root and, unlike a lazily-created hash file, cannot collide
    # when two equivalent configured spellings are launched together.
    current_scan_index=${#scan_roots[@]}
    scan_output="$tmp_dir/scan-$current_scan_index"
    scan_roots+=("$root")
    scan_outputs+=("$scan_output")
    scan_statuses+=("1")
    scan_pids+=("")
    scan_purge_targets "$root" "$scan_output" < /dev/null >/dev/null 2>&1 &
    scan_pids[$current_scan_index]=$!
    pending_scan_indices+=("$current_scan_index")

    if [[ ${#pending_scan_indices[@]} -ge $max_scan_jobs ]]; then
        wait_scan_batch
    fi
done
wait_scan_batch

process_scan_output() {
    local root="$1" output="$2" item project_root reported_risk bytes
    [[ -f "$output" ]] || return 0
    while IFS= read -r item; do
        [[ -n "$item" && -d "$item" ]] || continue
        is_safe_project_artifact "$item" "$root" || continue
        is_protected_purge_artifact "$item" && continue
        project_root=$(find_purge_project_root_for_artifact "$item" 2>/dev/null || true)
        project_root=$(sm_project_real_directory "$project_root" 2>/dev/null || true)
        item=$(sm_project_real_directory "$item" 2>/dev/null || true)
        [[ -n "$project_root" && -n "$item" && "$item" == "$project_root/"* ]] || continue
        sm_project_classify_artifact "$item" "$project_root"
        [[ "$SM_ARTIFACT_KIND" != "unknown" ]] || continue
        sm_purge_capture_activity "$project_root"
        reported_risk="$SM_ARTIFACT_RISK"
        if [[ "$SM_PURGE_ACTIVITY_RESULT" != "idle" && "$reported_risk" != "protected" ]]; then
            reported_risk="protected"
        fi
        bytes=$(du -sk "$item" 2>/dev/null | awk '{print $1 * 1024}')
        [[ "$bytes" =~ ^[0-9]+$ ]] || bytes=0
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$bytes" "$reported_risk" \
            "$SM_ARTIFACT_KIND" "$SM_PURGE_ACTIVITY_RESULT" "$project_root" "$item"
    done < "$output"
}

# Consume results in configured-root order. A failed root has always been
# ignored by this bridge; retaining that behavior keeps partial scans fail-closed
# while allowing completed sibling roots to contribute candidates.
for ((scan_index = 0; scan_index < ${#scan_roots[@]}; scan_index++)); do
    [[ "${scan_statuses[$scan_index]:-1}" -eq 0 ]] || continue
    process_scan_output "${scan_roots[$scan_index]}" "${scan_outputs[$scan_index]}"
done
