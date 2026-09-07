#!/bin/bash
# Move explicitly selected AI Skills and MCP caches to Trash.
# Only direct user Skill children and exact rebuildable MCP cache roots are accepted.
set -euo pipefail

[[ "${FORGESWEEP_FULL_DISK_AUTHORIZED:-0}" == "1" ]] || {
    echo "error: Full Disk Access is required for AI content cleanup" >&2
    exit 77
}
[[ "${SIMPLEMOLE_EXECUTION_MODE:-manual}" == "manual" ]] || {
    echo "error: AI Skills and MCP inventory require explicit manual selection" >&2
    exit 2
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1090
source "$SCRIPT_DIR/lib/core/common.sh"
# shellcheck disable=SC1090
source "$SCRIPT_DIR/bin/app_runtime_guard.sh"

export MOLE_CURRENT_COMMAND="clean"
export SIMPLEMOLE_DELETE_MODE="trash"
simplemole_configure_delete_mode
load_mole_whitelist

HOME_DIR="${HOME%/}"
skill_roots=(
    "$HOME_DIR/.codex/skills"
    "$HOME_DIR/.claude/skills"
    "$HOME_DIR/.agents/skills"
    "$HOME_DIR/.agents/shared-skills"
    "$HOME_DIR/.cursor/skills"
    "$HOME_DIR/.gemini/skills"
)
mcp_roots=(
    "$HOME_DIR/.cache/chrome-devtools-mcp/chrome-profile"
    "$HOME_DIR/.cache/devin/cli/mcp"
)

has_control_characters() {
    local value="${1:-}"
    [[ "$value" == *$'\t'* || "$value" == *$'\n'* || "$value" == *$'\r'* ]]
}

has_symlink_ancestor_below_home() {
    local candidate="$1" current="${candidate%/*}"
    while [[ -n "$current" && "$current" != "$HOME_DIR" && "$current" != "/" ]]; do
        [[ -L "$current" ]] && return 0
        current="${current%/*}"
        [[ -n "$current" ]] || current="/"
    done
    return 1
}

is_direct_skill_item() {
    local candidate="$1" root="" leaf=""
    for root in "${skill_roots[@]}"; do
        [[ -d "$root" && ! -L "$root" ]] || continue
        [[ "${candidate%/*}" == "$root" ]] || continue
        leaf="${candidate##*/}"
        [[ -n "$leaf" && "$leaf" != .* && "$leaf" != ".system" ]] || return 1
        [[ -d "$candidate" || -L "$candidate" ]] || return 1
        [[ -f "$candidate/SKILL.md" ]] || return 1
        has_symlink_ancestor_below_home "$candidate" && return 1
        return 0
    done
    return 1
}

is_known_mcp_cache() {
    local candidate="$1" root="" marker="" npx_root="$HOME_DIR/.npm/_npx"
    [[ -d "$candidate" && ! -L "$candidate" ]] || return 1
    has_symlink_ancestor_below_home "$candidate" && return 1
    for root in "${mcp_roots[@]}"; do
        [[ "$candidate" == "$root" ]] && return 0
    done
    if [[ "${candidate%/*}" == "$npx_root" && -d "$npx_root" && ! -L "$npx_root" ]]; then
        marker=$(/usr/bin/find -P "$candidate/node_modules" -maxdepth 4 \
            \( -type d -o -type f \) -iname '*mcp*' -print -quit 2>/dev/null || true)
        [[ -n "$marker" ]] && return 0
    fi
    return 1
}

is_allowed_ai_inventory_path() {
    local candidate="${1:-}"
    [[ -n "$candidate" && "$candidate" == /* ]] || return 1
    has_control_characters "$candidate" && return 1
    case "$candidate" in *'/../'*|*/..|*'/./'*|*/.) return 1 ;; esac
    is_direct_skill_item "$candidate" || is_known_mcp_cache "$candidate"
}

simplemole_ai_inventory_guard() {
    local candidate="${1:-}" state=0
    is_allowed_ai_inventory_path "$candidate" || return 1
    load_mole_whitelist
    is_path_whitelisted "$candidate" && return 1
    # A user's unrelated Node.js development process must not block removing
    # a manually selected Skill.  Protect only the clients that can actually
    # own the selected AI/MCP inventory; the MCP bridge is covered by its
    # concrete executable (or its npx launcher), not every `node` process.
    simplemole_any_process_state \
        Codex codex Claude claude Cursor Code gemini chrome-devtools-mcp devin npx \
        || state=$?
    [[ "$state" -eq 1 ]]
}

simplemole_install_delete_final_guard simplemole_ai_inventory_guard || {
    echo "error: could not install final AI inventory guard" >&2
    exit 1
}

removed=0
skipped=0
failed=0
while IFS= read -r -d '' path; do
    identity=""
    if ! IFS= read -r -d '' identity; then
        echo "error: missing identity for AI inventory path: $path" >&2
        failed=$((failed + 1))
        break
    fi
    if [[ ! "$identity" =~ ^[0-9]+:[0-9]+:[0-9]+$ ]]; then
        echo "error: invalid or unavailable identity for AI inventory path: $path" >&2
        failed=$((failed + 1))
        continue
    fi
    if ! simplemole_ai_inventory_guard "$path"; then
        echo "error: refusing unapproved or active AI inventory path: $path" >&2
        failed=$((failed + 1))
        continue
    fi
    if mole_delete "$path" false "$identity"; then
        removed=$((removed + 1))
    else
        failed=$((failed + 1))
    fi
done

printf 'removed=%s\nskipped=%s\nfailed=%s\n' "$removed" "$skipped" "$failed"
[[ "$failed" -eq 0 ]]
