#!/bin/bash
# ForgeSweep native system data preview.
#
# Read-only inventory of root-owned system data, grouped for the System Data
# page. Executed through the signed privileged bridge because the scanned
# roots are root-owned; it never deletes anything.
#
# One TSV line per candidate (the apply bridge re-verifies every field):
#   entry<TAB>bytes<TAB>group<TAB>risk<TAB>name<TAB>detail<TAB>path
#   group: logs|reports|power|caches|updates    risk: safe|review
set -euo pipefail

user_name="${1:?missing user}"
user_home="${2:?missing home}"
export HOME="$user_home" USER="$user_name" LOGNAME="$user_name"

# Bound the report so a pathological log directory cannot flood the UI.
MAX_ROWS_PER_GROUP="${SM_SYSTEM_PREVIEW_MAX_ROWS:-400}"

TMP_FILES=""
cleanup() {
    [[ -z "$TMP_FILES" ]] || /bin/rm -f $TMP_FILES
}
trap cleanup EXIT

new_tmp() {
    local tmp
    tmp=$(/usr/bin/mktemp "${TMPDIR:-/tmp}/forgesweep-system-preview.XXXXXX") || exit 1
    TMP_FILES="$TMP_FILES $tmp"
    printf '%s' "$tmp"
}

# Name/detail must never smuggle tabs or newlines into the TSV stream.
sanitize() {
    printf '%s' "$1" | /usr/bin/tr '\t\r\n' '   '
}

age_days() {
    local mtime now
    mtime=$(/usr/bin/stat -f '%m' "$1" 2>/dev/null) || return 0
    now=$(/bin/date '+%s')
    [[ "$mtime" =~ ^[0-9]+$ && "$now" =~ ^[0-9]+$ ]] || return 0
    printf '%d' $(( (now - mtime) / 86400 ))
}

# Turn a "bytes<TAB>path" scratch file into capped, size-sorted entry lines.
emit_sorted() {
    local scratch="$1" group="$2" risk="$3" count=0 bytes path name detail parent
    [[ -s "$scratch" ]] || return 0
    while IFS="$(printf '\t')" read -r bytes path; do
        [[ "$bytes" =~ ^[0-9]+$ && "$bytes" -gt 0 ]] || continue
        [[ -n "$path" && "$path" == /* ]] || continue
        name=$(sanitize "${path##*/}")
        parent=$(sanitize "${path%/*}")
        detail=$(sanitize "$(age_days "$path")d · ${parent}")
        printf 'entry\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$bytes" "$group" "$risk" "$name" "$detail" "$path"
        count=$((count + 1))
        [[ "$count" -ge "$MAX_ROWS_PER_GROUP" ]] && break
    done < <(/usr/bin/sort -t "$(printf '\t')" -k1,1 -rn "$scratch" 2>/dev/null)
}

# Old plain files (logs, reports, power): exact files past an age threshold.
# "$4" (optional) is a subtree prefix excluded from every root, so a file is
# never reported by two groups with different age thresholds.
scan_file_group() {
    local group="$1" risk="$2" min_age="$3" exclude_prefix="$4"; shift 4
    local scratch path bytes root
    scratch=$(new_tmp)
    for root in "$@"; do
        [[ -d "$root" && ! -L "$root" ]] || continue
        while IFS= read -r -d '' path; do
            # A tab in a filename cannot survive the TSV protocol; skip it.
            case "$path" in *$'\t'*) continue ;; esac
            [[ -z "$exclude_prefix" ]] || case "$path" in "$exclude_prefix"*) continue ;; esac
            bytes=$(/usr/bin/stat -f '%z' "$path" 2>/dev/null) || continue
            [[ "$bytes" =~ ^[0-9]+$ && "$bytes" -gt 0 ]] || continue
            printf '%s\t%s\n' "$bytes" "$path" >> "$scratch"
        done < <(/usr/bin/find -P "$root" -xdev -type f -mtime "+$min_age" \
            -size +0c -print0 2>/dev/null)
    done
    emit_sorted "$scratch" "$group" "$risk"
}

# Top-level entries of one root (system caches, update payloads). Files are
# sized with stat and directories with du; symlinks never enter the report.
scan_entry_group() {
    local group="$1" risk="$2" min_age="$3" root="$4"
    local scratch path bytes kb
    scratch=$(new_tmp)
    [[ -d "$root" && ! -L "$root" ]] || return 0
    while IFS= read -r -d '' path; do
        case "$path" in *$'\t'*) continue ;; esac
        # index.plist is Software Update metadata; it must survive every clean.
        [[ "$path" == "/Library/Updates/index.plist" ]] && continue
        [[ -L "$path" ]] && continue
        if [[ -f "$path" ]]; then
            bytes=$(/usr/bin/stat -f '%z' "$path" 2>/dev/null) || continue
        elif [[ -d "$path" ]]; then
            kb=$(/usr/bin/du -skP "$path" 2>/dev/null | /usr/bin/awk '{print $1}') || continue
            [[ "$kb" =~ ^[0-9]+$ && "$kb" -gt 0 ]] || continue
            bytes=$((kb * 1024))
        else
            continue
        fi
        [[ "$bytes" =~ ^[0-9]+$ && "$bytes" -gt 0 ]] || continue
        printf '%s\t%s\n' "$bytes" "$path" >> "$scratch"
    done < <(/usr/bin/find -P "$root" -mindepth 1 -maxdepth 1 \
        -mtime "+$min_age" -print0 2>/dev/null)
    emit_sorted "$scratch" "$group" "$risk"
}

# System logs (>= 14 days). Crash reports own the DiagnosticReports subtree.
scan_file_group logs safe 14 "/Library/Logs/DiagnosticReports" \
    /Library/Logs /private/var/log
scan_file_group reports safe 30 "" \
    /Library/Logs/DiagnosticReports /private/var/db/DiagnosticPipeline
scan_file_group power safe 30 "" \
    /private/var/db/powerlog
# Root-owned caches (>= 30 days): rebuildable, still reviewed per entry.
scan_entry_group caches safe 30 /Library/Caches
# Staged Software Update payloads (>= 30 days): keep the review badge.
scan_entry_group updates review 30 /Library/Updates
