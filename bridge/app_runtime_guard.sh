#!/bin/bash
# Shared tri-state process probe for final cleanup bridges.
# Return: 0 = one of the named processes is active, 1 = conclusively idle,
# 2 = process state unavailable. Callers must treat 0 and 2 as protected.

# Cleanup initiated from the disk-clean page opts into permanent deletion.
# Every other caller keeps the recoverable Trash default, and malformed modes
# fail closed instead of being forwarded to Mole.
simplemole_configure_delete_mode() {
    local requested="${SIMPLEMOLE_DELETE_MODE:-trash}"
    case "$requested" in
        trash|permanent) export MOLE_DELETE_MODE="$requested" ;;
        *)
            printf 'error: invalid cleanup delete mode: %s\n' "$requested" >&2
            return 1
            ;;
    esac
}

_simplemole_test_process_state() {
    local state=""
    if [[ -n "${MOLE_TEST_PROCESS_STATE_SEQUENCE:-}" ]]; then
        state="${MOLE_TEST_PROCESS_STATE_SEQUENCE%%,*}"
        if [[ "$MOLE_TEST_PROCESS_STATE_SEQUENCE" == *,* ]]; then
            MOLE_TEST_PROCESS_STATE_SEQUENCE="${MOLE_TEST_PROCESS_STATE_SEQUENCE#*,}"
        else
            MOLE_TEST_PROCESS_STATE_SEQUENCE=""
        fi
    else
        state="${MOLE_TEST_PROCESS_STATE:-idle}"
    fi
    case "$state" in
        active) return 0 ;;
        idle) return 1 ;;
        *) return 2 ;;
    esac
}

simplemole_any_process_state() {
    if [[ "${MOLE_TEST_MODE:-0}" == "1" ]]; then
        local test_state=0
        _simplemole_test_process_state || test_state=$?
        return "$test_state"
    fi

    command -v pgrep >/dev/null 2>&1 || return 2
    local name="" escaped="" pattern="" character="" probe_status=0 index=0
    for name in "$@"; do
        [[ -n "$name" ]] || return 2
        # pgrep accepts an extended regular expression. Escape every operator
        # that can occur in an executable name, then probe all trusted names in
        # one process-table snapshot instead of starting pgrep once per name.
        escaped=""
        for ((index = 0; index < ${#name}; index++)); do
            character="${name:index:1}"
            case "$character" in
                '\\'|'.'|'^'|'$'|'|'|'('|')'|'['|']'|'{'|'}'|'*'|'+'|'?')
                    escaped="${escaped}\\${character}"
                    ;;
                *) escaped="${escaped}${character}" ;;
            esac
        done
        pattern="${pattern:+$pattern|}$escaped"
    done
    [[ -n "$pattern" ]] || return 1

    if pgrep -x "$pattern" >/dev/null 2>&1; then
        return 0
    else
        probe_status=$?
        [[ "$probe_status" -eq 1 ]] && return 1
        return 2
    fi
}

simplemole_package_manager_state() {
    simplemole_any_process_state \
        npm node pnpm yarn java gradle mvn go cargo rustc dotnet \
        python python3 pip uv brew swift swift-build swift-package \
        php composer bazel zig mix elixir erl beam.smp hex dart flutter pub
}

SIMPLEMOLE_OPEN_SNAPSHOT_STATE="unprepared"
SIMPLEMOLE_OPEN_SNAPSHOT_FILE=""
SIMPLEMOLE_BUNDLE_SNAPSHOT_STATE="unprepared"
SIMPLEMOLE_BUNDLE_SNAPSHOT_FILE=""

# One cleanup plan needs one process/open-file inventory. Re-running global
# lsof and NSWorkspace once per path was the dominant cost for large batches.
simplemole_prepare_open_file_snapshot() {
    local lsof_bin="" errors="" status=0
    [[ "$SIMPLEMOLE_OPEN_SNAPSHOT_STATE" == "unprepared" ]] || {
        [[ "$SIMPLEMOLE_OPEN_SNAPSHOT_STATE" == "ready" ]]
        return
    }
    SIMPLEMOLE_OPEN_SNAPSHOT_STATE="unavailable"
    lsof_bin=$(command -v lsof 2>/dev/null || true)
    [[ -n "$lsof_bin" && -x "$lsof_bin" ]] || return 2
    errors=$(create_temp_file 2>/dev/null || true)
    SIMPLEMOLE_OPEN_SNAPSHOT_FILE=$(create_temp_file 2>/dev/null || true)
    [[ -n "$errors" && -f "$errors" && ! -L "$errors" &&
       -n "$SIMPLEMOLE_OPEN_SNAPSHOT_FILE" &&
       -f "$SIMPLEMOLE_OPEN_SNAPSHOT_FILE" &&
       ! -L "$SIMPLEMOLE_OPEN_SNAPSHOT_FILE" ]] || return 2

    run_with_timeout 8 "$lsof_bin" -nP -Fpn \
        > "$SIMPLEMOLE_OPEN_SNAPSHOT_FILE" 2> "$errors" || status=$?
    if [[ "$status" -eq 0 && ! -s "$errors" ]]; then
        SIMPLEMOLE_OPEN_SNAPSHOT_STATE="ready"
        rm -f -- "$errors"
        return 0
    fi
    rm -f -- "$errors" "$SIMPLEMOLE_OPEN_SNAPSHOT_FILE"
    SIMPLEMOLE_OPEN_SNAPSHOT_FILE=""
    return 2
}

# Return 0 when a path is open, 1 when the shared lsof snapshot proves it idle,
# and 2 when the snapshot is unavailable. The final sink still invokes this
# function immediately before mutation; only the read-only inventory is shared.
simplemole_path_open_state() {
    local candidate="$1"
    if [[ "${MOLE_TEST_MODE:-0}" == "1" ]]; then
        local test_state=0
        _simplemole_test_process_state || test_state=$?
        return "$test_state"
    fi
    [[ -e "$candidate" || -L "$candidate" ]] || return 2
    simplemole_prepare_open_file_snapshot || return 2
    if grep -Fqx -- "n$candidate" "$SIMPLEMOLE_OPEN_SNAPSHOT_FILE" 2>/dev/null; then
        return 0
    fi
    if [[ -d "$candidate" ]] &&
        grep -Fq -- "n$candidate/" "$SIMPLEMOLE_OPEN_SNAPSHOT_FILE" 2>/dev/null; then
        return 0
    fi
    return 1
}

# Hard automation boundary shared by Quick Clean's generic sink. App-owned
# cache databases remain eligible, but models, user sessions and Docker state
# are never touched automatically even when nested inside a cache root.
simplemole_forbidden_automatic_path() {
    local value="$1" lower="" leaf="" extension=""
    lower=$(printf '%s' "$value" | LC_ALL=C tr '[:upper:]' '[:lower:]') || return 0
    leaf="${lower##*/}"
    extension="${leaf##*.}"
    case "$lower" in
        */sessions|*/sessions/*|*/conversations|*/conversations/*|\
        */userdata|*/userdata/*|*/user\ data|*/user\ data/*|\
        */.codex/sessions|*/.codex/sessions/*|*/.codex/log|*/.codex/log/*|\
        */.codex/auth.json|*/.codex/history.jsonl|*/.claude/projects|\
        */.claude/projects/*|*/.claude/todos|*/.claude/todos/*|\
        */.claude/shell-snapshots|*/.claude/shell-snapshots/*|\
        */.local/share/opencode/project|*/.local/share/opencode/project/*|\
        */.gemini|*/.gemini/*|*/models|*/models/*|*/.ollama/models|\
        */.ollama/models/*|*/.cache/huggingface|*/.cache/huggingface/*|\
        */.cache/lm-studio/models|*/.cache/lm-studio/models/*|\
        */.cache/torch|*/.cache/torch/*|*/.docker|*/.docker/*|\
        */library/containers/com.docker.docker|*/library/containers/com.docker.docker/*|\
        */library/group\ containers/group.com.docker|\
        */library/group\ containers/group.com.docker/*)
            return 0
            ;;
    esac
    case "$leaf" in pytorch_model.bin|adapter_model.bin|model.bin|docker.raw|docker.qcow2)
        return 0
        ;;
    esac
    case "$extension" in gguf|safetensors|ckpt|mlmodel|mlmodelc|pt|pth|onnx|tflite)
        return 0
        ;;
    esac
    return 1
}

# Return 0 when forbidden automation content exists, 1 for a complete clear
# traversal, and 2 when traversal is incomplete.
simplemole_automatic_content_state() {
    local candidate="$1" listing="" item=""
    simplemole_forbidden_automatic_path "$candidate" && return 0
    [[ -d "$candidate" ]] || return 1
    listing=$(create_temp_file 2>/dev/null || true)
    [[ -n "$listing" && -f "$listing" && ! -L "$listing" ]] || return 2
    if ! /usr/bin/find -P "$candidate" -xdev -print0 > "$listing" 2>/dev/null; then
        rm -f -- "$listing"
        return 2
    fi
    while IFS= read -r -d '' item; do
        if simplemole_forbidden_automatic_path "$item"; then
            rm -f -- "$listing"
            return 0
        fi
    done < "$listing"
    rm -f -- "$listing"
    return 1
}

simplemole_is_home_trash_item() {
    local candidate="$1" prefix="$HOME/.Trash/" remainder=""
    [[ "$candidate" == "$prefix"* ]] || return 1
    remainder="${candidate#"$prefix"}"
    [[ -n "$remainder" && "$remainder" != */* ]]
}

simplemole_trash_sensitive_path() {
    local value="$1" lower="" leaf="" extension=""
    lower=$(printf '%s' "$value" | LC_ALL=C tr '[:upper:]' '[:lower:]') || return 0
    leaf="${lower##*/}"
    extension="${leaf##*.}"
    simplemole_forbidden_automatic_path "$value" && return 0
    case "$leaf" in
        cookies|history|login\ data|web\ data|bookmarks|preferences|secure\ preferences|\
        *-wal|*-shm|*-journal)
            return 0
            ;;
    esac
    case "$extension" in db|sqlite|sqlite3) return 0 ;; esac
    case "$lower" in *.app|*.app/*) return 0 ;; esac
    return 1
}

# Trash is the only generic Safe source that may contain arbitrary user data.
# Traverse it once at the final boundary and reject sessions, models, app
# bundles, browser identity stores and database families.
simplemole_trash_content_state() {
    local candidate="$1" listing="" item=""
    simplemole_is_home_trash_item "$candidate" || return 2
    simplemole_trash_sensitive_path "$candidate" && return 0
    [[ -d "$candidate" ]] || return 1
    listing=$(create_temp_file 2>/dev/null || true)
    [[ -n "$listing" && -f "$listing" && ! -L "$listing" ]] || return 2
    if ! /usr/bin/find -P "$candidate" -xdev -print0 > "$listing" 2>/dev/null; then
        rm -f -- "$listing"
        return 2
    fi
    while IFS= read -r -d '' item; do
        if simplemole_trash_sensitive_path "$item"; then
            rm -f -- "$listing"
            return 0
        fi
    done < "$listing"
    rm -f -- "$listing"
    return 1
}

# Manual review may include Warning content when it is routed to recoverable
# Trash. The disk-clean page uses permanent deletion, so it gets the same
# recursive sensitive-content boundary as Quick Clean/automation even though
# the user confirmed the individual cache row.
simplemole_execution_content_allowed() {
    local candidate="$1" content_state=0
    case "${SIMPLEMOLE_EXECUTION_MODE:-manual}" in
        manual)
            if [[ "${SIMPLEMOLE_DELETE_MODE:-trash}" != "permanent" ]]; then
                return 0
            fi
            simplemole_automatic_content_state "$candidate" || content_state=$?
            [[ "$content_state" -eq 1 ]]
            ;;
        quickClean|automatic)
            simplemole_automatic_content_state "$candidate" || content_state=$?
            [[ "$content_state" -eq 1 ]]
            ;;
        *) return 1 ;;
    esac
}

# Resolve a reverse-DNS cache path to its owning bundle identifier. Only the
# direct component under ~/Library/Caches is accepted; malformed identifiers
# are passed to the state probe so it can fail closed.
simplemole_reverse_dns_cache_owner() {
    local path="$1"
    local prefix="$HOME/Library/Caches/"
    local container_prefix="$HOME/Library/Containers/"
    local remainder="" owner="" suffix=""

    if [[ "$path" == "$prefix"* ]]; then
        remainder="${path#"$prefix"}"
        owner="${remainder%%/*}"
    elif [[ "$path" == "$container_prefix"* ]]; then
        remainder="${path#"$container_prefix"}"
        owner="${remainder%%/*}"
        suffix="${remainder#*/}"
        case "$suffix" in
            Data/Library/Caches|Data/Library/Caches/*|Data/Library/Logs|Data/Library/Logs/*) ;;
            *) return 1 ;;
        esac
    else
        return 1
    fi
    [[ "$owner" == *.* && "$owner" != .* ]] || return 1
    printf '%s\n' "$owner"
}

simplemole_prepare_running_bundle_snapshot() {
    local state=""
    [[ "$SIMPLEMOLE_BUNDLE_SNAPSHOT_STATE" == "unprepared" ]] || {
        [[ "$SIMPLEMOLE_BUNDLE_SNAPSHOT_STATE" == "ready" ]]
        return
    }
    SIMPLEMOLE_BUNDLE_SNAPSHOT_STATE="unavailable"
    [[ -x /usr/bin/osascript ]] || return 2
    SIMPLEMOLE_BUNDLE_SNAPSHOT_FILE=$(create_temp_file 2>/dev/null || true)
    [[ -n "$SIMPLEMOLE_BUNDLE_SNAPSHOT_FILE" &&
       -f "$SIMPLEMOLE_BUNDLE_SNAPSHOT_FILE" &&
       ! -L "$SIMPLEMOLE_BUNDLE_SNAPSHOT_FILE" ]] || return 2
    state=$(run_with_timeout 5 /usr/bin/osascript -l JavaScript -e '
        function run() {
            ObjC.import("AppKit");
            const apps = $.NSWorkspace.sharedWorkspace.runningApplications.js;
            if (!apps || apps.length === 0) return "__unknown__";
            const result = ["__complete__"];
            for (let index = 0; index < apps.length; index += 1) {
                const identifier = ObjC.unwrap(apps[index].bundleIdentifier);
                if (identifier && !apps[index].terminated) result.push(String(identifier).toLowerCase());
            }
            return result.join("\\n");
        }
    ' 2>/dev/null) || return 2
    [[ "$state" == __complete__* ]] || return 2
    printf '%s\n' "$state" > "$SIMPLEMOLE_BUNDLE_SNAPSHOT_FILE" || return 2
    SIMPLEMOLE_BUNDLE_SNAPSHOT_STATE="ready"
    return 0
}

# Return: 0 = the bundle owner is active, 1 = conclusively idle,
# 2 = state unavailable. The exact executable leaf is checked for CLI-style
# owners, then LaunchServices is queried through NSWorkspace without sending
# Apple Events. An empty application list is not evidence that the owner is
# idle (for example, when the login session cannot be queried).
simplemole_bundle_identifier_state() {
    local bundle_identifier="$1"
    local executable_leaf="${bundle_identifier##*.}"
    local probe_status=0 state=""

    if [[ "${MOLE_TEST_MODE:-0}" == "1" ]]; then
        local test_state=0
        _simplemole_test_process_state || test_state=$?
        return "$test_state"
    fi

    [[ "$bundle_identifier" == *.* && "$bundle_identifier" != .* &&
        "$bundle_identifier" != *. && "$bundle_identifier" != *..* &&
        "$bundle_identifier" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || return 2
    command -v pgrep >/dev/null 2>&1 || return 2
    if pgrep -x "$executable_leaf" >/dev/null 2>&1; then
        return 0
    else
        probe_status=$?
        [[ "$probe_status" -eq 1 ]] || return 2
    fi

    simplemole_prepare_running_bundle_snapshot || return 2
    if grep -Fiqx -- "$bundle_identifier" "$SIMPLEMOLE_BUNDLE_SNAPSHOT_FILE" 2>/dev/null; then
        return 0
    fi
    return 1
}

# Mole performs size accounting between a bridge's policy check and its Trash
# move. Install a narrow wrapper around that final move so a route-specific,
# fresh guard runs after accounting and identity checks, immediately before the
# recoverable mutation. The original function comes from the trusted bundled
# Mole library; only its function name is changed.
simplemole_install_trash_final_guard() {
    local guard_name="$1"
    local definition=""

    declare -F "$guard_name" >/dev/null 2>&1 || return 1
    declare -F _mole_move_to_trash >/dev/null 2>&1 || return 1

    if ! declare -F _simplemole_original_move_to_trash >/dev/null 2>&1; then
        definition=$(declare -f _mole_move_to_trash) || return 1
        definition="${definition/#_mole_move_to_trash ()/_simplemole_original_move_to_trash ()}"
        [[ "$definition" == _simplemole_original_move_to_trash* ]] || return 1
        eval "$definition"

        _mole_move_to_trash() {
            local final_guard="${_SIMPLEMOLE_TRASH_FINAL_GUARD:-}"
            if [[ -n "$final_guard" ]] &&
                declare -F "$final_guard" >/dev/null 2>&1 &&
                ! "$final_guard" "${1:-}"; then
                return 1
            fi
            _simplemole_original_move_to_trash "$@"
        }
    fi

    _SIMPLEMOLE_TRASH_FINAL_GUARD="$guard_name"
}

# Mole's optional sink hook runs after size and identity verification and just
# before either permanent removal or a Trash move. It is used by disk cleanup;
# legacy Trash-only callers retain the wrapper above unchanged.
simplemole_install_delete_final_guard() {
    local guard_name="$1"
    [[ "$guard_name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
    declare -F "$guard_name" >/dev/null 2>&1 || return 1
    MOLE_DELETE_FINAL_GUARD="$guard_name"
    export MOLE_DELETE_FINAL_GUARD
}
