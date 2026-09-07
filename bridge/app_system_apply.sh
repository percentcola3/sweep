#!/bin/bash
# ForgeSweep native system apply. The privileged launcher validates the signed
# App before invoking this script; this script validates the reviewed plan and
# performs only exact root-owned file removals.
set -euo pipefail

user_name="${1:?missing user}"
user_home="${2:?missing home}"
selected_file="${3:?missing selection file}"
expected_sha256="${4:?missing selection hash}"

fail_selection() {
    printf 'invalid selection file: %s\n' "$1" >&2
    exit 2
}

[[ "$expected_sha256" =~ ^[[:xdigit:]]{64}$ ]] || fail_selection "invalid SHA-256"
expected_sha256=$(printf '%s' "$expected_sha256" | /usr/bin/tr '[:upper:]' '[:lower:]')
[[ "$selected_file" == /* ]] || fail_selection "path must be absolute"
[[ -f "$selected_file" && ! -L "$selected_file" ]] || fail_selection "not a regular file"

expected_uid=$(/usr/bin/id -u "$user_name" 2>/dev/null) || fail_selection "unknown user"
file_uid=$(/usr/bin/stat -f '%u' "$selected_file" 2>/dev/null) || fail_selection "cannot stat owner"
[[ "$file_uid" == "$expected_uid" ]] || fail_selection "unexpected owner"
file_mode=$(/usr/bin/stat -f '%Lp' "$selected_file" 2>/dev/null) || fail_selection "cannot stat permissions"
[[ "$file_mode" =~ ^0?[0-7]{3}$ ]] || fail_selection "invalid permissions"
[[ "${file_mode#0}" == "600" ]] || fail_selection "permissions must be 0600"

# Read the user-owned plan through one descriptor, then copy it to a private
# root-only directory. The GUI digest binds the privileged operation to the
# exact bytes reviewed by the user.
exec 3< "$selected_file" || fail_selection "cannot open"
path_inode=$(/usr/bin/stat -L -f '%i' "$selected_file" 2>/dev/null) || fail_selection "cannot restat"
fd_inode=$(/usr/bin/stat -f '%i' /dev/fd/3 2>/dev/null) || fail_selection "cannot stat open file"
[[ "$path_inode" == "$fd_inode" ]] || fail_selection "changed while opening"
old_umask=$(umask)
umask 077
stage_dir=$(/usr/bin/mktemp -d /private/tmp/forgesweep-system-selection.XXXXXX) || fail_selection "cannot create private directory"
umask "$old_umask"
staged_file="$stage_dir/selection.bin"
trap 'exec 3<&- 2>/dev/null || true; /bin/rm -rf "$stage_dir"' EXIT
/usr/bin/head -c 16777217 <&3 > "$staged_file" || fail_selection "cannot stage"
exec 3<&-
staged_size=$(/usr/bin/stat -f '%z' "$staged_file" 2>/dev/null) || fail_selection "cannot stat staged copy"
[[ "$staged_size" -le 16777216 ]] || fail_selection "selection is too large"
actual_sha256=$(/usr/bin/shasum -a 256 "$staged_file" 2>/dev/null | /usr/bin/awk '{print $1}') || fail_selection "cannot hash staged copy"
[[ "$actual_sha256" == "$expected_sha256" ]] || fail_selection "SHA-256 mismatch"

is_allowed_system_path() {
    case "$1" in
        /Library/Logs/*|/private/var/log/*|/private/var/db/DiagnosticPipeline/*|/private/var/db/powerlog/*|/Library/Caches/*|/Library/Updates/*)
            return 0 ;;
        *) return 1 ;;
    esac
}

# Software Update's own bookkeeping must survive every clean.
is_never_delete_path() {
    [[ "$1" == "/Library/Updates/index.plist" ]]
}

# Remove a verified directory without rm -rf: enumerate post-order, unlink
# files and rmdir directories. Anything that appeared between the walk and
# the removal leaves the parent non-empty, so rmdir fails closed instead of
# deleting content the plan never saw. Symlinks are left in place for the
# same reason (their parent then fails rmdir and is reported, not guessed).
remove_directory_fail_closed() {
    local dir="$1" entry rc=0
    while IFS= read -r -d '' entry; do
        if [[ -L "$entry" ]]; then
            continue
        elif [[ -d "$entry" ]]; then
            /bin/rmdir -- "$entry" 2>/dev/null || rc=1
        elif [[ -f "$entry" ]]; then
            /bin/rm -f -- "$entry" 2>/dev/null || rc=1
        fi
    done < <(/usr/bin/find -P "$dir" -xdev -depth -print0 2>/dev/null)
    [[ $rc -eq 0 ]] || return 1
    /bin/rmdir -- "$dir" 2>/dev/null || return 1
    [[ ! -e "$dir" ]]
}

path_bytes() {
    local path="$1" kb
    if [[ -d "$path" && ! -L "$path" ]]; then
        kb=$(/usr/bin/du -skP "$path" 2>/dev/null | /usr/bin/awk '{print $1}')
        [[ "$kb" =~ ^[0-9]+$ && "$kb" -gt 0 ]] && printf '%s' $((kb * 1024)) || printf '0'
    else
        /usr/bin/stat -f '%z' "$path" 2>/dev/null || printf '0'
    fi
}

is_path_whitelisted() {
    local path="$1" line
    local whitelist="$user_home/.config/mole/whitelist"
    [[ -f "$whitelist" && ! -L "$whitelist" ]] || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        line=$(trim_line "$line")
        [[ -n "$line" && "${line:0:1}" != "#" ]] || continue
        [[ "$path" == "$line" || "$path" == "$line"/* ]] && return 0
    done < "$whitelist"
    return 1
}

# Bash 3.2 does not enable extglob by default; keep whitespace trimming simple
# and leave non-path lines untouched.
trim_line() {
    printf '%s' "$1" | /usr/bin/sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

removed=0
skipped=0
failed=0
removed_bytes=0
while IFS= read -r -d '' path && IFS= read -r -d '' expected_identity; do
    [[ -n "$path" ]] || continue
    if is_never_delete_path "$path" \
        || ! is_allowed_system_path "$path" \
        || [[ "$expected_identity" != "" && ! "$expected_identity" =~ ^[0-9]+:[0-9]+:[0-9]+$ ]]; then
        failed=$((failed + 1))
        continue
    fi
    if [[ ! -e "$path" || -L "$path" ]]; then
        skipped=$((skipped + 1))
        continue
    fi
    current_identity=$(/usr/bin/stat -f '%d:%i:%m' "$path" 2>/dev/null || true)
    if [[ -z "$expected_identity" || "$current_identity" != "$expected_identity" ]]; then
        skipped=$((skipped + 1))
        continue
    fi
    owner=$(/usr/bin/stat -f '%u' "$path" 2>/dev/null || echo -1)
    if [[ "$owner" != "0" ]]; then
        skipped=$((skipped + 1))
        continue
    fi
    if is_path_whitelisted "$path"; then
        skipped=$((skipped + 1))
        continue
    fi
    bytes=$(path_bytes "$path")
    if [[ -d "$path" ]]; then
        if remove_directory_fail_closed "$path"; then
            removed=$((removed + 1))
            [[ "$bytes" =~ ^[0-9]+$ ]] && removed_bytes=$((removed_bytes + bytes))
        else
            failed=$((failed + 1))
        fi
    elif /bin/rm -f -- "$path"; then
        removed=$((removed + 1))
        [[ "$bytes" =~ ^[0-9]+$ ]] && removed_bytes=$((removed_bytes + bytes))
    else
        failed=$((failed + 1))
    fi
done < "$staged_file"
printf 'removed=%s\nskipped=%s\nfailed=%s\nremoved_bytes=%s\n' \
    "$removed" "$skipped" "$failed" "$removed_bytes"
[[ "$failed" -eq 0 ]]
