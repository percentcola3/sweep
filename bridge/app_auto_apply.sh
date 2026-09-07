#!/bin/bash
# Apply automatic-cleanup candidates selected by the app.
# Records are NUL-delimited
# root/authorized-root-device:inode:birth/path/device:inode:mtime/
# latest-descendant-mtime/safety-token tuples.
# The rule root, static safety policy, open-file state and item identity are all
# revalidated here before the final Mole Trash sink.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1090
source "$SCRIPT_DIR/lib/core/common.sh"
# shellcheck disable=SC1090
source "$SCRIPT_DIR/bin/app_runtime_guard.sh"

export MOLE_CURRENT_COMMAND="clean"
export MOLE_DELETE_MODE="trash"
load_mole_whitelist

removed=0
skipped=0
failed=0

has_unsafe_path_syntax() {
    local value="$1"
    [[ "$value" =~ [[:cntrl:]] ]] && return 0
    [[ "$value" =~ (^|/)\.\.?(/|$) ]]
}

is_protected_auto_content_path() {
    local value="$1" lower leaf extension
    lower=$(printf '%s' "$value" | LC_ALL=C tr '[:upper:]' '[:lower:]') || return 0
    leaf="${lower##*/}"
    extension="${leaf##*.}"

    case "$lower" in
        */.git|*/.git/*|*/.hg|*/.hg/*|*/.svn|*/.svn/*|*/.ssh|*/.ssh/*|*/.gnupg|*/.gnupg/*|\
        */models|*/models/*|*/sessions|*/sessions/*|*/conversations|*/conversations/*|\
        */userdata|*/userdata/*|*/user\ data|*/user\ data/*|*/databases|*/databases/*|\
        */docker|*/docker/*|*/vms|*/vms/*|*/.codex/sessions|*/.codex/sessions/*|\
        */.codex/log|*/.codex/log/*|*/.codex/auth.json|*/.codex/history.jsonl|\
        */.claude/projects|*/.claude/projects/*|*/.claude/todos|*/.claude/todos/*|\
        */.claude/shell-snapshots|*/.claude/shell-snapshots/*|\
        */.local/share/opencode/project|*/.local/share/opencode/project/*|\
        */.gemini|*/.gemini/*|*/.ollama/models|*/.ollama/models/*|\
        */.cache/huggingface|*/.cache/huggingface/*|\
        */.cache/lm-studio/models|*/.cache/lm-studio/models/*|\
        */.cache/torch|*/.cache/torch/*)
            return 0
            ;;
    esac
    case "$leaf" in
        .env|.env.*|credentials|credentials.json|cookies|history|login\ data|wallet.dat|\
        pytorch_model.bin|adapter_model.bin|model.bin|\
        package.json|package-lock.json|pnpm-lock.yaml|yarn.lock|cargo.toml|cargo.lock|\
        pyproject.toml|poetry.lock|go.mod|go.sum|podfile|podfile.lock|package.swift|\
        pubspec.yaml|pubspec.lock|dockerfile|docker-compose.yml)
            return 0
            ;;
    esac
    case "$extension" in
        pem|key|p12|pfx|mobileprovision|sqlite|sqlite3|db|gguf|safetensors|ckpt|\
        mlmodel|mlmodelc|pt|pth|onnx|tflite)
            return 0
            ;;
    esac
    return 1
}

# 0 = protected content found, 1 = complete scan and none found, 2 = unknown.
automatic_content_state() {
    local candidate="$1" listing="" item=""
    if is_protected_auto_content_path "$candidate"; then
        return 0
    fi
    [[ -d "$candidate" ]] || return 1

    listing=$(create_temp_file 2>/dev/null || true)
    [[ -n "$listing" && -f "$listing" && ! -L "$listing" ]] || return 2
    if ! /usr/bin/find -P "$candidate" -xdev -print0 > "$listing" 2>/dev/null; then
        rm -f -- "$listing"
        return 2
    fi
    while IFS= read -r -d '' item; do
        if is_protected_auto_content_path "$item"; then
            rm -f -- "$listing"
            return 0
        fi
    done < "$listing"
    rm -f -- "$listing"
    return 1
}

# Print the newest whole-second mtime across the exact candidate tree. Match
# the Swift planner: do not follow symlinks and do not include descendant link
# metadata. Any incomplete traversal fails closed.
automatic_latest_mtime() {
    local candidate="$1" listing="" item="" item_mtime="" newest=0
    if [[ ! -d "$candidate" || -L "$candidate" ]]; then
        item_mtime=$("$STAT_BSD" -f%m "$candidate" 2>/dev/null) || return 2
        [[ "$item_mtime" =~ ^[0-9]+$ ]] || return 2
        printf '%s\n' "$item_mtime"
        return 0
    fi

    listing=$(create_temp_file 2>/dev/null || true)
    [[ -n "$listing" && -f "$listing" && ! -L "$listing" ]] || return 2
    if ! /usr/bin/find -P "$candidate" -xdev -print0 > "$listing" 2>/dev/null; then
        rm -f -- "$listing"
        return 2
    fi
    while IFS= read -r -d '' item; do
        if [[ "$item" != "$candidate" && -L "$item" ]]; then
            continue
        fi
        item_mtime=$("$STAT_BSD" -f%m "$item" 2>/dev/null) || {
            rm -f -- "$listing"
            return 2
        }
        [[ "$item_mtime" =~ ^[0-9]+$ ]] || {
            rm -f -- "$listing"
            return 2
        }
        (( item_mtime > newest )) && newest="$item_mtime"
    done < "$listing"
    rm -f -- "$listing"
    printf '%s\n' "$newest"
}

# 0 = open/in use, 1 = conclusively idle, 2 = probe unavailable or failed.
automatic_path_open_state() {
    local candidate="$1" lsof_bin="" errors="" output="" rc=0
    if [[ "${MOLE_TEST_MODE:-0}" == "1" ]]; then
        case "${MOLE_TEST_LSOF_STATE:-unknown}" in
            idle) return 1 ;;
            open) return 0 ;;
            *) return 2 ;;
        esac
    fi

    lsof_bin=$(command -v lsof 2>/dev/null || true)
    [[ -n "$lsof_bin" && -x "$lsof_bin" ]] || return 2
    errors=$(create_temp_file 2>/dev/null || true)
    [[ -n "$errors" && -f "$errors" && ! -L "$errors" ]] || return 2

    if [[ -d "$candidate" ]]; then
        output=$(run_with_timeout 8 "$lsof_bin" -Fn +D "$candidate" 2> "$errors") || rc=$?
    else
        output=$(run_with_timeout 8 "$lsof_bin" -Fn -- "$candidate" 2> "$errors") || rc=$?
    fi
    if [[ "$rc" -eq 0 && -n "$output" ]]; then
        rm -f -- "$errors"
        return 0
    fi
    if [[ "$rc" -eq 1 && ! -s "$errors" ]]; then
        rm -f -- "$errors"
        return 1
    fi
    rm -f -- "$errors"
    return 2
}

is_forbidden_auto_root() {
    local root="$1"
    local physical_root="$2"

    # A whole account is never a disposable cache root, including aliases to
    # HOME. Mole's shared policy covers system and other high-risk roots.
    if [[ -e "$HOME" && "$root" -ef "$HOME" ]]; then
        return 0
    fi
    if _mole_is_critical_deletion_path "$root"; then
        return 0
    fi
    if [[ "$physical_root" != "$root" ]] &&
        _mole_is_critical_deletion_path "$physical_root"; then
        return 0
    fi
    return 1
}

SIMPLEMOLE_AUTO_GUARD_PATH=""
SIMPLEMOLE_AUTO_EXPECTED_LATEST_MTIME=""
SIMPLEMOLE_AUTO_ROOT=""
SIMPLEMOLE_AUTO_EXPECTED_ROOT_IDENTITY=""

simplemole_auto_final_guard() {
    local candidate="$1" content_state=0 open_state=0 latest="" root_identity=""
    [[ "$candidate" == "$SIMPLEMOLE_AUTO_GUARD_PATH" &&
        "$SIMPLEMOLE_AUTO_EXPECTED_LATEST_MTIME" =~ ^[0-9]+$ ]] || return 1
    load_mole_whitelist
    is_path_whitelisted "$candidate" && return 1
    root_identity=$("$STAT_BSD" -f%d:%i:%B "$SIMPLEMOLE_AUTO_ROOT" 2>/dev/null) || return 1
    [[ "$root_identity" == "$SIMPLEMOLE_AUTO_EXPECTED_ROOT_IDENTITY" ]] || return 1

    automatic_content_state "$candidate" || content_state=$?
    [[ "$content_state" -eq 1 ]] || return 1
    latest=$(automatic_latest_mtime "$candidate") || return 1
    [[ "$latest" == "$SIMPLEMOLE_AUTO_EXPECTED_LATEST_MTIME" ]] || return 1
    automatic_path_open_state "$candidate" || open_state=$?
    [[ "$open_state" -eq 1 ]]
}

simplemole_install_trash_final_guard simplemole_auto_final_guard || {
    echo "error: could not install final automatic-cleanup guard"
    exit 1
}

while IFS= read -r -d '' root; do
    authorized_root_identity=""
    path=""
    identity=""
    planned_latest_mtime=""
    safety_token=""
    if ! IFS= read -r -d '' authorized_root_identity; then
        echo "error: missing authorized root identity: $root"
        failed=$((failed + 1))
        break
    fi
    if ! IFS= read -r -d '' path; then
        echo "error: missing path for automatic cleanup root: $root"
        failed=$((failed + 1))
        break
    fi
    if ! IFS= read -r -d '' identity; then
        echo "error: missing identity for automatic cleanup path: $path"
        failed=$((failed + 1))
        break
    fi
    if ! IFS= read -r -d '' planned_latest_mtime; then
        echo "error: missing latest mtime for automatic cleanup path: $path"
        failed=$((failed + 1))
        break
    fi
    if ! IFS= read -r -d '' safety_token; then
        echo "error: missing safety token for automatic cleanup path: $path"
        failed=$((failed + 1))
        break
    fi

    # Ignore harmless trailing separators on the configured root. Never do
    # this for the item path: a trailing slash could dereference a leaf link.
    while [[ "$root" != "/" && "$root" == */ ]]; do
        root="${root%/}"
    done

    if [[ "$root" != /* || "$path" != /* ]] ||
        has_unsafe_path_syntax "$root" || has_unsafe_path_syntax "$path" ||
        [[ "$path" == */ ]]; then
        echo "error: invalid automatic cleanup root or path: $root -> $path"
        failed=$((failed + 1))
        continue
    fi
    if [[ ! "$authorized_root_identity" =~ ^[0-9]+:[0-9]+:[0-9]+$ ||
        ! "$identity" =~ ^[0-9]+:[0-9]+:[0-9]+$ ||
        ! "$planned_latest_mtime" =~ ^[0-9]+$ ]]; then
        echo "error: invalid identity for automatic cleanup path: $path"
        failed=$((failed + 1))
        continue
    fi
    if [[ "$safety_token" != "safe-trash-v4" ]]; then
        echo "error: automatic cleanup rule requires renewed Safe authorization: $path"
        failed=$((failed + 1))
        continue
    fi
    if [[ -L "$root" || ! -d "$root" ]]; then
        echo "error: automatic cleanup root is not a real directory: $root"
        failed=$((failed + 1))
        continue
    fi

    physical_root=$(cd -P "$root" 2>/dev/null && pwd -P) || physical_root=""
    if [[ -z "$physical_root" || "$physical_root" != "$root" ]] ||
        is_forbidden_auto_root "$root" "$physical_root"; then
        echo "error: refusing high-risk automatic cleanup root: $root"
        failed=$((failed + 1))
        continue
    fi
    current_root_identity=$("$STAT_BSD" -f%d:%i:%B "$root" 2>/dev/null || true)
    if [[ "$current_root_identity" != "$authorized_root_identity" ]]; then
        echo "error: automatic cleanup root changed after authorization: $root"
        failed=$((failed + 1))
        continue
    fi

    path_parent="${path%/*}"
    [[ -n "$path_parent" ]] || path_parent="/"
    path_name="${path##*/}"
    if [[ "$path_parent" != "$root" || -z "$path_name" ]]; then
        echo "error: automatic cleanup path is not a direct child of its root: $path"
        failed=$((failed + 1))
        continue
    fi

    physical_parent=$(cd -P "$path_parent" 2>/dev/null && pwd -P) || physical_parent=""
    if [[ -z "$physical_parent" || "$physical_parent" != "$physical_root" ]]; then
        echo "error: automatic cleanup path escaped its physical root: $path"
        failed=$((failed + 1))
        continue
    fi
    if [[ ! -e "$path" && ! -L "$path" ]]; then
        echo "error: automatic cleanup path no longer exists: $path"
        failed=$((failed + 1))
        continue
    fi

    current_identity=$("$STAT_BSD" -f%d:%i:%m "$path" 2>/dev/null || true)
    if [[ "$current_identity" != "$identity" ]]; then
        echo "error: automatic cleanup path identity changed: $path"
        failed=$((failed + 1))
        continue
    fi
    if is_path_whitelisted "$path"; then
        skipped=$((skipped + 1))
        continue
    fi

    content_state=0
    automatic_content_state "$path" || content_state=$?
    if [[ "$content_state" -eq 0 ]]; then
        echo "error: refusing protected model, session, project, credential, database or Docker content: $path"
        failed=$((failed + 1))
        continue
    fi
    if [[ "$content_state" -ne 1 ]]; then
        echo "error: unable to prove automatic cleanup content is Safe: $path"
        failed=$((failed + 1))
        continue
    fi

    open_state=0
    automatic_path_open_state "$path" || open_state=$?
    if [[ "$open_state" -eq 0 ]]; then
        echo "error: automatic cleanup path is in use: $path"
        failed=$((failed + 1))
        continue
    fi
    if [[ "$open_state" -ne 1 ]]; then
        echo "error: unable to verify automatic cleanup path is idle: $path"
        failed=$((failed + 1))
        continue
    fi

    current_latest_mtime=$(automatic_latest_mtime "$path") || current_latest_mtime=""
    if [[ -z "$current_latest_mtime" ||
        "$current_latest_mtime" != "$planned_latest_mtime" ]]; then
        echo "error: automatic cleanup path changed after planning: $path"
        failed=$((failed + 1))
        continue
    fi

    # mole_delete binds the leaf and its physical parent again immediately
    # before moving it. For a symlink leaf, stat and mv operate on the link.
    SIMPLEMOLE_AUTO_GUARD_PATH="$path"
    SIMPLEMOLE_AUTO_EXPECTED_LATEST_MTIME="$planned_latest_mtime"
    SIMPLEMOLE_AUTO_ROOT="$root"
    SIMPLEMOLE_AUTO_EXPECTED_ROOT_IDENTITY="$authorized_root_identity"
    if mole_delete "$path" false "$identity"; then
        removed=$((removed + 1))
    else
        failed=$((failed + 1))
    fi
done

printf 'removed=%s\nskipped=%s\nfailed=%s\n' "$removed" "$skipped" "$failed"
[[ "$failed" -eq 0 ]]
