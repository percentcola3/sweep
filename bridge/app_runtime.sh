#!/bin/bash
# Runtime bridge for the native app. Manual destructive modes require a
# `pid|start-identity` token captured by the corresponding scan. Automatic
# stale-process cleanup uses the narrower `pid|start-identity|ppid|uid` token.

set -euo pipefail
export LC_ALL=C

mode="${1:-}"
PS_BIN=/bin/ps
PGREP_BIN=/usr/bin/pgrep
KILL_BIN=/bin/kill
LSOF_BIN=/usr/sbin/lsof
if [[ "${MOLE_TEST_MODE:-0}" == "1" ]]; then
    PS_BIN="${MOLE_TEST_PS_BIN:-$PS_BIN}"
    PGREP_BIN="${MOLE_TEST_PGREP_BIN:-$PGREP_BIN}"
    KILL_BIN="${MOLE_TEST_KILL_BIN:-$KILL_BIN}"
    LSOF_BIN="${MOLE_TEST_LSOF_BIN:-$LSOF_BIN}"
fi

valid_start_identity() {
    [[ "$1" =~ ^[A-Z][a-z]{2}_[A-Z][a-z]{2}_[0-9]{1,2}_[0-9]{2}:[0-9]{2}:[0-9]{2}_[0-9]{4}$ ]]
}

process_start_identity() {
    local pid="$1" raw
    raw=$("$PS_BIN" -p "$pid" -o lstart= 2>/dev/null) || return 1
    printf '%s\n' "$raw" | /usr/bin/awk '
        NF >= 5 {
            printf "%s_%s_%s_%s_%s\n", $1, $2, $3, $4, $5
            found = 1
            exit
        }
        END { if (!found) exit 1 }
    '
}

verify_process_identity() {
    local pid="$1" expected="$2" current
    current=$(process_start_identity "$pid") || return 1
    [[ "$current" == "$expected" ]]
}

is_forgesweep_pid() {
    local candidate="$1" mole_pid
    while read -r mole_pid; do
        [[ "$mole_pid" =~ ^[0-9]+$ ]] || continue
        [[ "$candidate" != "$mole_pid" ]] || return 0
    done < <("$PGREP_BIN" -x ForgeSweep 2>/dev/null || true)
    return 1
}

parse_signal_target() {
    local target="${1:-}"
    [[ "$target" == *"|"* ]] || return 1
    signal_pid="${target%%|*}"
    signal_identity="${target#*|}"
    [[ "$signal_pid" =~ ^[0-9]+$ && "$signal_pid" -gt 1 ]] || return 1
    valid_start_identity "$signal_identity"
}

parse_stale_target() {
    local target="${1:-}" extra=""
    IFS='|' read -r stale_pid stale_identity stale_ppid stale_uid extra <<< "$target"
    [[ -z "$extra" ]] || return 1
    [[ "$stale_pid" =~ ^[0-9]+$ && "$stale_pid" -gt 1 ]] || return 1
    [[ "$stale_ppid" =~ ^[0-9]+$ && "$stale_ppid" -ge 1 ]] || return 1
    [[ "$stale_uid" =~ ^[0-9]+$ ]] || return 1
    valid_start_identity "$stale_identity"
}

# Output: ppid<TAB>uid<TAB>start-identity<TAB>state<TAB>comm. Keep comm as the
# final field because executable paths may contain spaces.
process_snapshot() {
    local pid="$1" raw
    raw=$("$PS_BIN" -p "$pid" -o ppid=,uid=,lstart=,state=,comm= 2>/dev/null) || return 1
    printf '%s\n' "$raw" | /usr/bin/awk '
        NF >= 9 {
            ppid=$1; uid=$2
            started=$3 "_" $4 "_" $5 "_" $6 "_" $7
            state=$8
            for (field=1; field<=8; field++) $field=""
            sub(/^[ \t]+/, "")
            printf "%s\t%s\t%s\t%s\t%s\n", ppid, uid, started, state, $0
            found = 1
            exit
        }
        END { if (!found) exit 1 }
    '
}

read_process_snapshot() {
    local pid="$1" line
    line=$(process_snapshot "$pid") || return 1
    IFS=$'\t' read -r snapshot_ppid snapshot_uid snapshot_identity snapshot_state snapshot_comm <<< "$line"
    [[ "$snapshot_ppid" =~ ^[0-9]+$ && "$snapshot_uid" =~ ^[0-9]+$ ]] || return 1
    valid_start_identity "$snapshot_identity" || return 1
    [[ -n "$snapshot_state" && -n "$snapshot_comm" ]]
}

is_protected_command() {
    local command="$1"
    # Unknown/non-absolute executable identities fail closed. /bin is included
    # with the requested system roots because it is also macOS-owned.
    [[ "$command" == /* ]] || return 0
    case "$command" in
        /System|/System/*|/usr|/usr/*|/sbin|/sbin/*|/private|/private/*|/bin|/bin/*)
            return 0
            ;;
    esac
    return 1
}

# Return success when either PID is the other PID's ancestor. This protects the
# app/bridge tree without relying only on a process name.
pids_share_lineage() {
    local first="$1" second="$2" process_tree
    [[ "$first" == "$second" ]] && return 0
    process_tree=$("$PS_BIN" -axo pid=,ppid= 2>/dev/null) || return 2
    printf '%s\n' "$process_tree" | /usr/bin/awk -v first="$first" -v second="$second" '
        { parent[$1] = $2 }
        END {
            current = first
            for (step = 0; current > 1 && step < 256; step++) {
                if (current == second) exit 0
                if (!(current in parent) || parent[current] == current) break
                current = parent[current]
            }
            current = second
            for (step = 0; current > 1 && step < 256; step++) {
                if (current == first) exit 0
                if (!(current in parent) || parent[current] == current) break
                current = parent[current]
            }
            exit 1
        }
    '
}

is_protected_runtime_pid() {
    local candidate="$1" app_pid app_pids="" probe_status=0 lineage_status=0 app_name
    pids_share_lineage "$candidate" "$$" || lineage_status=$?
    [[ "$lineage_status" -eq 1 ]] || return 0

    for app_name in ForgeSweep SimpleMole; do
        probe_status=0
        app_pids=$("$PGREP_BIN" -x "$app_name" 2>/dev/null) || probe_status=$?
        # pgrep 1 conclusively means no match; every other error fails closed.
        [[ "$probe_status" -eq 0 || "$probe_status" -eq 1 ]] || return 0
        while read -r app_pid; do
            [[ "$app_pid" =~ ^[0-9]+$ ]] || continue
            lineage_status=0
            pids_share_lineage "$candidate" "$app_pid" || lineage_status=$?
            [[ "$lineage_status" -eq 1 ]] || return 0
        done <<< "$app_pids"
    done
    return 1
}

snapshot_matches_stale_target() {
    [[ "$snapshot_ppid" == "$stale_ppid" &&
       "$snapshot_uid" == "$stale_uid" &&
       "$snapshot_identity" == "$stale_identity" ]]
}

stale_identity_is_allowed() {
    local current_uid="${EUID:-$UID}"
    [[ "$stale_uid" == "$current_uid" ]] || return 1
    snapshot_matches_stale_target || return 1
    ! is_protected_runtime_pid "$stale_pid"
}

stale_target_is_allowed() {
    stale_identity_is_allowed || return 1
    ! is_protected_command "$snapshot_comm"
}

case "$mode" in
    processes)
        "$PS_BIN" -axo pid=,ppid=,uid=,lstart=,state=,etime=,pcpu=,pmem=,comm=,args= | /usr/bin/awk '
            BEGIN { OFS="\t" }
            {
                pid=$1; ppid=$2; uid=$3; started=$4 "_" $5 "_" $6 "_" $7 "_" $8
                state=$9; etime=$10; cpu=$11; mem=$12; comm=$13
                for (field=1; field<=13; field++) $field=""
                sub(/^[ \t]+/, "")
                if (pid ~ /^[0-9]+$/ && ppid ~ /^[0-9]+$/ && uid ~ /^[0-9]+$/)
                    print pid, ppid, uid, started, state, etime, cpu, mem, comm, $0
            }
        '
        ;;
    ports)
        while IFS=$'\t' read -r port pid command endpoint; do
            [[ "$pid" =~ ^[0-9]+$ && "$pid" -gt 1 ]] || continue
            identity=$(process_start_identity "$pid") || continue
            valid_start_identity "$identity" || continue
            printf '%s\t%s\t%s\t%s\t%s\n' "$port" "$pid" "$identity" "$command" "$endpoint"
        done < <("$LSOF_BIN" -nP -Fpcnt -a -iTCP -sTCP:LISTEN 2>/dev/null | /usr/bin/awk '
            BEGIN { OFS="\t"; pid=""; command=""; endpoint="" }
            /^p/ { pid=substr($0,2) }
            /^c/ { command=substr($0,2) }
            /^n/ {
                endpoint=substr($0,2)
                port=endpoint
                sub(/^.*:/, "", port)
                print port, pid, command, endpoint
            }
        ')
        ;;
    kill-pid)
        parse_signal_target "${2:-}" || { echo "invalid process identity" >&2; exit 2; }
        verify_process_identity "$signal_pid" "$signal_identity" || {
            echo "process changed or no longer exists" >&2
            exit 4
        }
        ! is_forgesweep_pid "$signal_pid" || {
            echo "refusing to terminate ForgeSweep" >&2
            exit 3
        }
        # Recheck immediately before the only destructive signal.
        verify_process_identity "$signal_pid" "$signal_identity" || {
            echo "process changed before signal" >&2
            exit 4
        }
        "$KILL_BIN" -TERM "$signal_pid"
        ;;
    kill-group)
        parse_signal_target "${2:-}" || { echo "invalid process identity" >&2; exit 2; }
        root="$signal_pid"
        root_identity="$signal_identity"
        verify_process_identity "$root" "$root_identity" || {
            echo "process group changed or no longer exists" >&2
            exit 4
        }

        tree_pids=()
        tree_identities=()
        collect_tree() {
            local parent="$1" child current
            while read -r child; do
                [[ "$child" =~ ^[0-9]+$ && "$child" -gt 1 ]] || continue
                collect_tree "$child" || return $?
            done < <("$PS_BIN" -axo pid=,ppid= | /usr/bin/awk -v parent="$parent" '$2 == parent {print $1}')
            current=$(process_start_identity "$parent") || {
                [[ "$parent" != "$root" ]]
                return $?
            }
            if [[ "$parent" == "$root" && "$current" != "$root_identity" ]]; then
                return 4
            fi
            tree_pids+=("$parent")
            tree_identities+=("$current")
        }
        collect_tree "$root" || {
            echo "process group changed while collecting its tree" >&2
            exit 4
        }

        # Complete a fail-closed preflight before signalling any tree member.
        tree_active=()
        for ((i = 0; i < ${#tree_pids[@]}; i++)); do
            pid="${tree_pids[$i]}"
            identity="${tree_identities[$i]}"
            current=$(process_start_identity "$pid") || {
                tree_active[$i]=false
                continue
            }
            [[ "$current" == "$identity" ]] || {
                echo "process tree changed before signal" >&2
                exit 4
            }
            ! is_forgesweep_pid "$pid" || {
                echo "refusing to terminate a tree containing ForgeSweep" >&2
                exit 3
            }
            tree_active[$i]=true
        done

        failed=0
        for ((i = 0; i < ${#tree_pids[@]}; i++)); do
            [[ "${tree_active[$i]:-false}" == "true" ]] || continue
            pid="${tree_pids[$i]}"
            identity="${tree_identities[$i]}"
            current=$(process_start_identity "$pid") || continue
            if [[ "$current" != "$identity" ]] || is_forgesweep_pid "$pid"; then
                failed=$((failed + 1))
                continue
            fi
            "$KILL_BIN" -TERM "$pid" 2>/dev/null || failed=$((failed + 1))
        done
        [[ "$failed" -eq 0 ]]
        ;;
    cleanup-stale)
        parse_stale_target "${2:-}" || { echo "invalid stale process identity" >&2; exit 2; }
        read_process_snapshot "$stale_pid" || {
            echo "stale process changed or no longer exists" >&2
            exit 4
        }
        initial_state="$snapshot_state"
        initial_comm="$snapshot_comm"

        if [[ "$initial_state" == Z* ]]; then
            # macOS may render a zombie command as <defunct>. The child itself
            # is never signalled, so bind its identity/tree here and apply the
            # executable-path gate to the parent that actually receives CHLD.
            stale_identity_is_allowed || {
                echo "zombie process is protected or changed" >&2
                exit 3
            }
            parent_pid="$stale_ppid"
            [[ "$parent_pid" -gt 1 ]] || {
                echo "zombie has no safe parent to notify" >&2
                exit 6
            }
            read_process_snapshot "$parent_pid" || {
                echo "zombie parent no longer exists" >&2
                exit 6
            }
            parent_ppid="$snapshot_ppid"
            parent_uid="$snapshot_uid"
            parent_identity="$snapshot_identity"
            parent_state="$snapshot_state"
            parent_comm="$snapshot_comm"
            [[ "$parent_uid" == "${EUID:-$UID}" && "$parent_state" != Z* && "$parent_state" != *E* ]] || {
                echo "zombie parent is not safe to notify" >&2
                exit 3
            }
            ! is_protected_command "$parent_comm" && ! is_protected_runtime_pid "$parent_pid" || {
                echo "zombie parent is protected" >&2
                exit 3
            }

            # Recheck both identities immediately before CHLD. Never send a
            # terminating signal to the zombie itself.
            read_process_snapshot "$parent_pid" || exit 6
            [[ "$snapshot_ppid" == "$parent_ppid" && "$snapshot_uid" == "$parent_uid" &&
               "$snapshot_identity" == "$parent_identity" && "$snapshot_state" == "$parent_state" &&
               "$snapshot_comm" == "$parent_comm" ]] || {
                echo "zombie parent changed before notification" >&2
                exit 4
            }
            read_process_snapshot "$stale_pid" || exit 0
            stale_identity_is_allowed &&
                [[ "$snapshot_state" == Z* && "$snapshot_comm" == "$initial_comm" ]] || {
                echo "zombie changed before notification" >&2
                exit 4
            }
            "$KILL_BIN" -CHLD "$parent_pid" || {
                echo "failed to notify zombie parent" >&2
                exit 7
            }
            /bin/sleep 0.2
            if ! read_process_snapshot "$stale_pid"; then
                exit 0
            fi
            if snapshot_matches_stale_target && [[ "$snapshot_state" == Z* && "$snapshot_comm" == "$initial_comm" ]]; then
                echo "zombie parent did not reap the child" >&2
                exit 6
            fi
            exit 0
        fi

        stale_target_is_allowed || {
            echo "stale process is protected or changed" >&2
            exit 3
        }
        [[ "$initial_state" == *E* ]] || {
            echo "process is not an automatic-cleanup candidate" >&2
            exit 5
        }
        # Recheck all captured fields immediately before TERM.
        read_process_snapshot "$stale_pid" || exit 0
        stale_target_is_allowed && [[ "$snapshot_state" == "$initial_state" && "$snapshot_comm" == "$initial_comm" ]] || {
            echo "stale process changed before TERM" >&2
            exit 4
        }
        "$KILL_BIN" -TERM "$stale_pid" || {
            echo "failed to terminate stale process" >&2
            exit 7
        }
        /bin/sleep 0.2
        read_process_snapshot "$stale_pid" || exit 0
        if ! snapshot_matches_stale_target || [[ "$snapshot_comm" != "$initial_comm" ]]; then
            exit 0
        fi
        [[ "$snapshot_state" == *E* && "$snapshot_state" != Z* ]] || {
            echo "stale process changed state after TERM" >&2
            exit 8
        }
        ! is_protected_command "$snapshot_comm" && ! is_protected_runtime_pid "$stale_pid" || {
            echo "stale process became protected before KILL" >&2
            exit 3
        }
        "$KILL_BIN" -KILL "$stale_pid" || {
            echo "failed to force stale process exit" >&2
            exit 7
        }
        /bin/sleep 0.2
        if read_process_snapshot "$stale_pid" && snapshot_matches_stale_target; then
            echo "stale process survived KILL" >&2
            exit 8
        fi
        ;;
    *)
        echo "usage: app_runtime.sh [processes|ports|kill-pid PID\|START|kill-group PID\|START|cleanup-stale PID\|START\|PPID\|UID]" >&2
        exit 2
        ;;
esac
