#!/bin/bash
# App bridge: inventory of AI tool sessions, caches and runtime leftovers.
# Read-only. TSV: bytes \t kind \t name \t path
#   kind=session  append-only session/log/snapshot history (analysis only)
#   kind=cache    tool-managed caches (safe to clean)
#   kind=model    model assets (display only; the apply bridge refuses them)
# Config, credentials and memory files are deliberately absent from this list.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1090
source "$SCRIPT_DIR/lib/core/common.sh"
source "$SCRIPT_DIR/bin/app_scan_access.sh"

# The normal cleanup pipeline asks for `--safe-only`.  Keeping the mode at the
# bridge boundary makes it impossible for a caller to accidentally turn the
# fast, automatic pass into a session/model inventory.  The full AI panel can
# omit the flag when it needs review-only session and model entries.
scan_mode="full"
case "${1:-}" in
    "") ;;
    --safe-only) scan_mode="safe-only" ;;
    --full) ;;
    *)
        printf 'error: invalid AI scan mode: %s\n' "$1" >&2
        exit 2
        ;;
esac

HOME_DIR="${HOME%/}"
[[ -n "$HOME_DIR" ]] || HOME_DIR="/"
load_mole_whitelist "$HOME_DIR"

# AI inventory is deliberately a fixed, read-only allowlist.  Rejecting a
# symlink at every path component matters even for a scanner: an attacker (or
# a redirected test HOME) could otherwise make `du` walk outside the named
# cache root and present a misleading size.  The apply bridge repeats the
# boundary immediately before mutation.
ai_scan_path_allowed() {
    local path="${1:-}" probe=""
    [[ "$path" == /* && ! "$path" =~ [[:cntrl:]] ]] || return 1
    [[ "$path" != *'/../'* && "$path" != */.. ]] || return 1
    case "$path" in
        "$HOME_DIR"|"$HOME_DIR"/*) ;;
        *) return 1 ;;
    esac
    probe="$path"
    while :; do
        [[ ! -L "$probe" ]] || return 1
        [[ "$probe" == "$HOME_DIR" ]] && break
        probe="${probe%/*}"
        [[ -n "$probe" && "$probe" != "/" ]] || return 1
    done
    is_path_whitelisted "$path" && return 1
    # The catalogued Library/Caches leaves are user-owned rebuildable data.
    # macOS does not need a Full Disk Access prompt for these explicit leaves,
    # and treating their parent as protected would make the safe AI pass ask
    # for authorization even though it never traverses another app's data.
    # Application Support and all other scopes still use the shared TCC gate.
    if [[ "$path" != "$HOME_DIR/Library/Caches/"* ]]; then
        forgesweep_scan_path_allowed "$path" || return 1
    fi
    return 0
}

declare -a emitted_paths=()

emit() {
    local bytes kind name path existing
    kind="$1"; name="$2"; path="$3"
    [[ "$scan_mode" != "safe-only" || "$kind" == "cache" ]] || return 0
    # Gemini's tmp tree contains conversation/session state and is intentionally
    # Protected by CleanupRiskPolicy.  Keep it available in the full AI panel,
    # but do not spend time walking it during the automatic safe pass.
    if [[ "$scan_mode" == "safe-only" &&
          ( "$path" == "$HOME_DIR/.gemini/tmp" ||
            "$path" == "$HOME_DIR/.gemini/tmp"/* ) ]]; then
        return 0
    fi
    ai_scan_path_allowed "$path" || return 0
    [[ -e "$path" ]] || return 0
    # Avoid duplicate work/counting if a future catalog adds nested roots.
    for existing in "${emitted_paths[@]+${emitted_paths[@]}}"; do
        [[ "$path" == "$existing" || "$path" == "$existing"/* ||
           "$existing" == "$path"/* ]] && return 0
    done
    bytes=$(du -skP "$path" 2>/dev/null | awk '{print $1 * 1024}')
    [[ "$bytes" =~ ^[0-9]+$ ]] || bytes=0
    [[ "$bytes" -gt 0 ]] || return 0
    printf '%s\t%s\t%s\t%s\n' "$bytes" "$kind" "$name" "$path"
    emitted_paths+=("$path")
}

# --- Claude Code（settings / CLAUDE.md / 凭据不在清单内）---
emit session "Claude Code sessions"        "$HOME_DIR/.claude/projects"
emit session "Claude Code shell snapshots" "$HOME_DIR/.claude/shell-snapshots"
emit session "Claude Code todos"           "$HOME_DIR/.claude/todos"
emit cache  "Claude Code telemetry cache"  "$HOME_DIR/.claude/statsig"

# --- Codex CLI ---
emit session "Codex sessions" "$HOME_DIR/.codex/sessions"
emit session "Codex logs"     "$HOME_DIR/.codex/log"
# Codex Desktop's cache root also contains durable Chromium state (cookies,
# IndexedDB, Local Storage and preferences).  Keep the automatic route to the
# six audited, rebuildable leaves only (the catalog label is "Codex desktop cache");
# emitting the parent would make a later
# apply call indistinguishable from a blanket profile wipe.
codex_cache_root="$HOME_DIR/Library/Caches/Codex"
for profile in \
    "$codex_cache_root/Default" \
    "$codex_cache_root/Default/Partitions/codex-browser-app" \
    "$codex_cache_root/codex-browser-app"; do
    emit cache "Codex Desktop cache" "$profile/Cache"
    emit cache "Codex Desktop code cache" "$profile/Code Cache"
done

# --- opencode / Gemini CLI ---
emit session "opencode sessions"    "$HOME_DIR/.local/share/opencode/project"
emit cache   "Gemini CLI temp data" "$HOME_DIR/.gemini/tmp"

# --- VSCode / Cursor 运行缓存 ---
for app_dir in "$HOME_DIR/Library/Application Support/Code" "$HOME_DIR/Library/Application Support/Cursor"; do
    app_name="VSCode"
    [[ "$app_dir" == *Cursor ]] && app_name="Cursor"
    emit cache "$app_name cache"                "$app_dir/Cache"
    emit cache "$app_name code cache"           "$app_dir/Code Cache"
    emit cache "$app_name GPU cache"            "$app_dir/GPUCache"
    emit cache "$app_name compiled cache"       "$app_dir/CachedData"
    emit cache "$app_name logs"                 "$app_dir/logs"
    emit cache "$app_name extension VSIX cache" "$app_dir/CachedExtensionVSIXs"
done

# --- Electron AI clients ---
# These are the same rebuildable Chromium leaves used by Mole's developer
# cleanup module.  Keep the application-support parents out of the catalog:
# settings, extensions, credentials and project state live beside these leaves
# and must remain review-only.  Each leaf is emitted separately so a user can
# select only one client's cache, and so deconfliction never turns a broad app
# support directory into an implicit delete.
antigravity_support="$HOME_DIR/Library/Application Support/Antigravity"
for antigravity_leaf in Cache "Code Cache" GPUCache DawnGraphiteCache DawnWebGPUCache; do
    emit cache "Antigravity $antigravity_leaf" "$antigravity_support/$antigravity_leaf"
done

filo_support="$HOME_DIR/Library/Application Support/Filo/production"
for filo_leaf in Cache "Code Cache" GPUCache DawnGraphiteCache DawnWebGPUCache; do
    emit cache "Filo $filo_leaf" "$filo_support/$filo_leaf"
done

claude_support="$HOME_DIR/Library/Application Support/Claude"
for claude_leaf in Cache "Code Cache" GPUCache DawnGraphiteCache DawnWebGPUCache sentry; do
    emit cache "Claude $claude_leaf" "$claude_support/$claude_leaf"
done

qoder_support="$HOME_DIR/Library/Application Support/Qoder"
for qoder_leaf in Cache CachedData CachedExtensionVSIXs "Code Cache" GPUCache DawnGraphiteCache DawnWebGPUCache logs; do
    emit cache "Qoder $qoder_leaf" "$qoder_support/$qoder_leaf"
done

# Prisma stores downloaded ORM engine binaries in its XDG cache. OpenCode's
# XDG cache is disposable; durable sessions are under
# ~/.local/share/opencode/project and are catalogued separately as review-only.
emit cache "Prisma cache" "$HOME_DIR/.cache/prisma"
emit cache "OpenCode cache" "$HOME_DIR/.cache/opencode"

# --- AI 相关浏览器 / 测试工具缓存 ---
emit cache "Playwright browsers"         "$HOME_DIR/Library/Caches/ms-playwright"
emit cache "Cypress binaries"            "$HOME_DIR/Library/Caches/Cypress"
emit cache "Puppeteer browsers"          "$HOME_DIR/.cache/puppeteer"
mcp_profile="$HOME_DIR/.cache/chrome-devtools-mcp/chrome-profile"
for mcp_cache_leaf in \
    "$mcp_profile/Default/Cache" \
    "$mcp_profile/Default/Code Cache" \
    "$mcp_profile/Default/GPUCache" \
    "$mcp_profile/Default/DawnGraphiteCache" \
    "$mcp_profile/Default/DawnWebGPUCache" \
    "$mcp_profile/Default/DawnCache" \
    "$mcp_profile/Default/GrShaderCache" \
    "$mcp_profile/Default/GraphiteDawnCache" \
    "$mcp_profile/GraphiteDawnCache" \
    "$mcp_profile/component_crx_cache" \
    "$mcp_profile/extensions_crx_cache" \
    "$mcp_profile/Default/Service Worker/CacheStorage"; do
    emit cache "Chrome DevTools MCP cache" "$mcp_cache_leaf"
done
emit cache "Electron download cache"     "$HOME_DIR/Library/Caches/electron"
emit cache "electron-builder cache"      "$HOME_DIR/Library/Caches/electron-builder"

# --- 模型资产（仅展示；apply 侧拒绝删除）---
emit model "HuggingFace models" "$HOME_DIR/.cache/huggingface"
emit model "Ollama models"      "$HOME_DIR/.ollama/models"
emit model "LM Studio models"   "$HOME_DIR/.cache/lm-studio/models"
emit model "PyTorch Hub cache"  "$HOME_DIR/.cache/torch"
