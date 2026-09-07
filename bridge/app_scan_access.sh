#!/bin/bash
# Shared read-only permission boundary for bridge scanners.
#
# Swift verifies Full Disk Access without touching Files & Folders protected
# locations, then exports FORGESWEEP_FULL_DISK_AUTHORIZED=1 to child processes.
# Bridge scripts must still fail closed when that capability is absent so a
# future call site cannot accidentally trigger native TCC folder prompts.

forgesweep_full_disk_access_granted() {
    [[ "${FORGESWEEP_FULL_DISK_AUTHORIZED:-0}" == "1" ]]
}

# Return success only for an absolute path that remains in the current user's
# home directory without crossing a symlinked ancestor. Scanner bridges use
# this before sizing a configured cache root; apply bridges repeat it before
# mutation. `du -P` does not protect the root itself (or a symlinked parent),
# so the lexical and ancestor checks belong at the bridge boundary as well.
#
# Missing leaf components are allowed: a scan may race with a cache writer and
# the caller can then skip the absent root. A missing ancestor, malformed path,
# or HOME=/ is rejected fail-closed.
forgesweep_scan_path_is_physical() {
    local path="${1:-}" home="${HOME%/}" probe=""
    [[ -n "$home" && "$home" != "/" ]] || return 1
    [[ "$path" == /* && ! "$path" =~ [[:cntrl:]] ]] || return 1
    case "$path" in
        *'/../'*|*/..|*'/./'*|*/.) return 1 ;;
    esac
    # `TMPDIR` and test/runtime launchers occasionally leave a doubled slash
    # in HOME. Collapse it before the containment check; repeated separators
    # are equivalent on macOS and rejecting them would hide otherwise safe
    # cache roots. Traversal components were rejected above before normalizing.
    while [[ "$path" == *//* ]]; do
        path="${path%%//*}/${path#*//*}"
    done
    while [[ "$home" == *//* ]]; do
        home="${home%%//*}/${home#*//*}"
    done
    while [[ "$path" != "/" && "$path" == */ ]]; do path="${path%/}"; done
    while [[ "$home" != "/" && "$home" == */ ]]; do home="${home%/}"; done
    [[ -n "$path" && -n "$home" ]] || return 1
    case "$path" in
        "$home"|"$home"/*) ;;
        *) return 1 ;;
    esac

    # HOME itself is normally a real directory on macOS. Rejecting a
    # symlinked HOME prevents a redirected test/runtime environment from
    # defeating the containment check below.
    [[ ! -L "$home" ]] || return 1
    probe="$path"
    while :; do
        [[ ! -L "$probe" ]] || return 1
        [[ "$probe" == "$home" ]] && return 0
        probe="${probe%/*}"
        [[ -n "$probe" && "$probe" != "/" ]] || return 1
    done
}

forgesweep_scan_path_is_protected() {
    local path="${1:-}" home="${HOME%/}"
    while [[ "$path" == *//* ]]; do path="${path//\/\//\/}"; done
    while [[ "$home" == *//* ]]; do home="${home//\/\//\/}"; done
    while [[ "$path" != "/" && "$path" == */ ]]; do path="${path%/}"; done
    [[ -n "$path" && -n "$home" ]] || return 0

    # Reject ambiguous lexical scopes and any directory that contains the
    # current home. A scanner rooted at / or /Users can reach every protected
    # folder even though the root string is not itself inside one.
    case "$path" in
        *'/../'*|*/..|*'/./'*|*/.) return 0 ;;
        /|/Users|/Volumes|/Volumes/*) return 0 ;;
    esac
    [[ "$home" == "$path/"* ]] && return 0

    # These user Library roots are intentionally limited to rebuildable tool
    # data and do not represent another App's private data.
    case "$path" in
        "$home/Library/Caches"|"$home/Library/Caches/"*|\
        "$home/Library/Developer"|"$home/Library/Developer/"*|\
        "$home/Library/Logs"|"$home/Library/Logs/"*|\
        "$home/Library/pnpm"|"$home/Library/pnpm/"*)
            return 1
            ;;
    esac

    case "$path" in
        "$home"|\
        "$home/Desktop"|"$home/Desktop/"*|\
        "$home/Documents"|"$home/Documents/"*|\
        "$home/Downloads"|"$home/Downloads/"*|\
        "$home/Pictures"|"$home/Pictures/"*|\
        "$home/Library"|"$home/Library/"*)
            return 0
            ;;
    esac

    # Other users' homes are always outside this process's normal scan scope.
    case "$path" in /Users/*) return 0 ;; esac
    return 1
}

# Return success when the path can be enumerated without prompting. Callers
# with mixed protected/unprotected roots should skip paths that return false.
forgesweep_scan_path_allowed() {
    local path="${1:-}"
    if forgesweep_scan_path_is_protected "$path"; then
        forgesweep_full_disk_access_granted
        return $?
    fi
    return 0
}

# Whole-scope scanners use this stricter form and exit with EX_NOPERM (77).
forgesweep_require_scan_path_access() {
    local path="${1:-}"
    if ! forgesweep_scan_path_allowed "$path"; then
        echo "error: Full Disk Access is required for protected scan path: $path" >&2
        return 77
    fi
    return 0
}
