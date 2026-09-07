#!/bin/bash
# Disk-analysis inventory for user-managed AI Skills and rebuildable MCP caches.
# Read-only TSV: bytes \t kind \t name \t path
# Credentials, MCP configuration files, sessions and built-in Skills are never emitted.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/app_scan_access.sh"

HOME_DIR="${HOME%/}"
if ! forgesweep_full_disk_access_granted; then
    echo "error: Full Disk Access is required for AI content inventory" >&2
    exit 77
fi

has_control_characters() {
    local value="${1:-}"
    [[ "$value" == *$'\t'* || "$value" == *$'\n'* || "$value" == *$'\r'* ]]
}

path_bytes() {
    local path="$1" bytes=""
    if [[ -L "$path" ]]; then
        bytes=$(/usr/bin/stat -f '%z' "$path" 2>/dev/null || true)
    elif [[ -d "$path" ]]; then
        bytes=$(/usr/bin/du -sk "$path" 2>/dev/null | /usr/bin/awk '{print $1 * 1024}')
    elif [[ -f "$path" ]]; then
        bytes=$(/usr/bin/stat -f '%z' "$path" 2>/dev/null || true)
    fi
    [[ "$bytes" =~ ^[0-9]+$ ]] || bytes=0
    printf '%s\n' "$bytes"
}

emit_item() {
    local kind="$1" name="$2" path="$3" bytes=""
    has_control_characters "$name" && return 0
    has_control_characters "$path" && return 0
    forgesweep_scan_path_allowed "$path" || return 0
    [[ -e "$path" || -L "$path" ]] || return 0
    bytes=$(path_bytes "$path")
    [[ "$bytes" =~ ^[0-9]+$ && "$bytes" -gt 0 ]] || return 0
    printf '%s\t%s\t%s\t%s\n' "$bytes" "$kind" "$name" "$path"
}

scan_skill_root() {
    local owner="$1" root="$2" item="" leaf="" kind=""
    [[ -d "$root" && ! -L "$root" ]] || return 0
    for item in "$root"/*; do
        [[ -e "$item" || -L "$item" ]] || continue
        leaf="${item##*/}"
        [[ -n "$leaf" && "$leaf" != .* ]] || continue
        [[ -f "$item/SKILL.md" ]] || continue
        kind="skill"
        [[ -L "$item" ]] && kind="skill_link"
        emit_item "$kind" "$owner · $leaf" "$item"
    done
}

scan_skill_root "Codex"  "$HOME_DIR/.codex/skills"
scan_skill_root "Claude" "$HOME_DIR/.claude/skills"
scan_skill_root "Agents" "$HOME_DIR/.agents/skills"
scan_skill_root "Agents" "$HOME_DIR/.agents/shared-skills"
scan_skill_root "Cursor" "$HOME_DIR/.cursor/skills"
scan_skill_root "Gemini" "$HOME_DIR/.gemini/skills"

# Known standalone MCP caches. Shared config files such as config.toml,
# .claude.json and mcp.json are deliberately excluded because deleting them
# would also remove unrelated settings, commands, environment and credentials.
emit_item "mcp_cache" "Chrome DevTools MCP cache" \
    "$HOME_DIR/.cache/chrome-devtools-mcp/chrome-profile"
emit_item "mcp_cache" "Devin MCP cache" "$HOME_DIR/.cache/devin/cli/mcp"

# npx installs are disposable package caches. Only expose a direct cache child
# when its node_modules tree contains an MCP-named package.
NPX_ROOT="$HOME_DIR/.npm/_npx"
if [[ -d "$NPX_ROOT" && ! -L "$NPX_ROOT" ]]; then
    for item in "$NPX_ROOT"/*; do
        [[ -d "$item" && ! -L "$item" ]] || continue
        marker=$(/usr/bin/find -P "$item/node_modules" -maxdepth 4 \
            \( -type d -o -type f \) -iname '*mcp*' -print -quit 2>/dev/null || true)
        [[ -n "$marker" ]] || continue
        emit_item "mcp_cache" "npx MCP cache · ${item##*/}" "$item"
    done
fi
