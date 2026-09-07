#!/bin/bash
# App bridge: remove verified rebuildable AI caches.
# Session history, model assets, credentials and configs are never accepted,
# including when stdin is hand-crafted outside the app.
set -euo pipefail

HOME_DIR="${HOME%/}"
[[ -n "$HOME_DIR" ]] || HOME_DIR="/"
cache_apps=(
    "$HOME_DIR/Library/Application Support/Code"
    "$HOME_DIR/Library/Application Support/Cursor"
)
cache_roots=(
    "$HOME_DIR/.claude/statsig"
    # Codex Desktop's profile root contains durable browser state.  Only its
    # six audited Chromium cache leaves are rebuildable and eligible here.
    "$HOME_DIR/Library/Caches/Codex/Default/Cache"
    "$HOME_DIR/Library/Caches/Codex/Default/Code Cache"
    "$HOME_DIR/Library/Caches/Codex/Default/Partitions/codex-browser-app/Cache"
    "$HOME_DIR/Library/Caches/Codex/Default/Partitions/codex-browser-app/Code Cache"
    "$HOME_DIR/Library/Caches/Codex/codex-browser-app/Cache"
    "$HOME_DIR/Library/Caches/Codex/codex-browser-app/Code Cache"
    "$HOME_DIR/Library/Caches/ms-playwright" "$HOME_DIR/Library/Caches/Cypress"
    "$HOME_DIR/.cache/puppeteer"
    "$HOME_DIR/.cache/chrome-devtools-mcp/chrome-profile/Default/Cache"
    "$HOME_DIR/.cache/chrome-devtools-mcp/chrome-profile/Default/Code Cache"
    "$HOME_DIR/.cache/chrome-devtools-mcp/chrome-profile/Default/GPUCache"
    "$HOME_DIR/.cache/chrome-devtools-mcp/chrome-profile/Default/DawnGraphiteCache"
    "$HOME_DIR/.cache/chrome-devtools-mcp/chrome-profile/Default/DawnWebGPUCache"
    "$HOME_DIR/.cache/chrome-devtools-mcp/chrome-profile/Default/DawnCache"
    "$HOME_DIR/.cache/chrome-devtools-mcp/chrome-profile/Default/GrShaderCache"
    "$HOME_DIR/.cache/chrome-devtools-mcp/chrome-profile/Default/GraphiteDawnCache"
    "$HOME_DIR/.cache/chrome-devtools-mcp/chrome-profile/GraphiteDawnCache"
    "$HOME_DIR/.cache/chrome-devtools-mcp/chrome-profile/component_crx_cache"
    "$HOME_DIR/.cache/chrome-devtools-mcp/chrome-profile/extensions_crx_cache"
    "$HOME_DIR/.cache/chrome-devtools-mcp/chrome-profile/Default/Service Worker/CacheStorage"
    "$HOME_DIR/Library/Caches/electron" "$HOME_DIR/Library/Caches/electron-builder"
    # Electron AI clients: only rebuildable Chromium/cache leaves are
    # allowlisted. Their application-support parents contain settings,
    # credentials, extensions and project state and are intentionally absent.
    "$HOME_DIR/Library/Application Support/Antigravity/Cache"
    "$HOME_DIR/Library/Application Support/Antigravity/Code Cache"
    "$HOME_DIR/Library/Application Support/Antigravity/GPUCache"
    "$HOME_DIR/Library/Application Support/Antigravity/DawnGraphiteCache"
    "$HOME_DIR/Library/Application Support/Antigravity/DawnWebGPUCache"
    "$HOME_DIR/Library/Application Support/Filo/production/Cache"
    "$HOME_DIR/Library/Application Support/Filo/production/Code Cache"
    "$HOME_DIR/Library/Application Support/Filo/production/GPUCache"
    "$HOME_DIR/Library/Application Support/Filo/production/DawnGraphiteCache"
    "$HOME_DIR/Library/Application Support/Filo/production/DawnWebGPUCache"
    "$HOME_DIR/Library/Application Support/Claude/Cache"
    "$HOME_DIR/Library/Application Support/Claude/Code Cache"
    "$HOME_DIR/Library/Application Support/Claude/GPUCache"
    "$HOME_DIR/Library/Application Support/Claude/DawnGraphiteCache"
    "$HOME_DIR/Library/Application Support/Claude/DawnWebGPUCache"
    "$HOME_DIR/Library/Application Support/Claude/sentry"
    "$HOME_DIR/Library/Application Support/Qoder/Cache"
    "$HOME_DIR/Library/Application Support/Qoder/CachedData"
    "$HOME_DIR/Library/Application Support/Qoder/CachedExtensionVSIXs"
    "$HOME_DIR/Library/Application Support/Qoder/Code Cache"
    "$HOME_DIR/Library/Application Support/Qoder/GPUCache"
    "$HOME_DIR/Library/Application Support/Qoder/DawnGraphiteCache"
    "$HOME_DIR/Library/Application Support/Qoder/DawnWebGPUCache"
    "$HOME_DIR/Library/Application Support/Qoder/logs"
    "$HOME_DIR/.cache/prisma" "$HOME_DIR/.cache/opencode"
)

# Do not allow a selected cache path to redirect through a symlink.  The
# generic Mole deletion sink also checks this at its final edge, but rejecting
# it here keeps the specialized allowlist honest and prevents stale identities
# from being collected for a different physical subtree.
simplemole_ai_path_is_physical() {
    local candidate="${1:-}" probe=""
    [[ "$candidate" == /* && ! "$candidate" =~ [[:cntrl:]] ]] || return 1
    [[ "$candidate" != *'/../'* && "$candidate" != */.. ]] || return 1
    case "$candidate" in
        "$HOME_DIR"|"$HOME_DIR"/*) ;;
        *) return 1 ;;
    esac
    probe="$candidate"
    while :; do
        [[ ! -L "$probe" ]] || return 1
        [[ "$probe" == "$HOME_DIR" ]] && break
        probe="${probe%/*}"
        [[ -n "$probe" && "$probe" != "/" ]] || return 1
    done
    return 0
}

is_allowed() {
    local candidate="$1" root
    simplemole_ai_path_is_physical "$candidate" || return 1
    for root in "${cache_roots[@]}"; do
        [[ "$candidate" == "$root" || "$candidate" == "$root"/* ]] && return 0
    done
    for root in "${cache_apps[@]}"; do
        case "$candidate" in
            "$root/Cache"|"$root/Cache"/*|"$root/Code Cache"|"$root/Code Cache"/*|\
            "$root/GPUCache"|"$root/GPUCache"/*|"$root/CachedData"|"$root/CachedData"/*|\
            "$root/logs"|"$root/logs"/*|"$root/CachedExtensionVSIXs"|"$root/CachedExtensionVSIXs"/*)
                return 0
                ;;
        esac
    done
    return 1
}

# Paths which the policy marks Protected are an integrity failure when they
# arrive at an apply bridge. Review-only session rows (for example ~/.codex)
# remain skippable, but a protected model or Gemini temporary tree must never
# be silently treated as an ordinary stale row.
simplemole_ai_path_is_protected() {
    local candidate="${1:-}"
    case "$candidate" in
        "$HOME_DIR/.gemini/tmp"|"$HOME_DIR/.gemini/tmp/"*|\
        "$HOME_DIR/.ollama/models"|"$HOME_DIR/.ollama/models/"*|\
        "$HOME_DIR/.cache/huggingface"|"$HOME_DIR/.cache/huggingface/"*|\
        "$HOME_DIR/.cache/lm-studio/models"|"$HOME_DIR/.cache/lm-studio/models/"*|\
        "$HOME_DIR/.cache/torch"|"$HOME_DIR/.cache/torch/"*)
            return 0
            ;;
    esac
    return 1
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1090
source "$SCRIPT_DIR/lib/core/common.sh"
source "$SCRIPT_DIR/bin/app_runtime_guard.sh"
export MOLE_CURRENT_COMMAND="clean"
simplemole_configure_delete_mode
load_mole_whitelist

removed=0
skipped=0
failed=0

simplemole_ai_path_guard() {
    local candidate="${1:-}" state=0
    if [[ "${MOLE_TEST_MODE:-0}" == "1" && -n "${SIMPLEMOLE_TEST_FINAL_GUARD_LOG:-}" ]]; then
        printf 'ai\n' >> "$SIMPLEMOLE_TEST_FINAL_GUARD_LOG"
    fi
    simplemole_ai_path_is_physical "$candidate" || return 1
    load_mole_whitelist
    is_path_whitelisted "$candidate" && return 1
    simplemole_execution_content_allowed "$candidate" || return 1
    # An unrelated AI/IDE process must not suppress every cache in the plan.
    # Check the selected subtree itself against the shared lsof snapshot: an
    # open file (or descendant) is protected, while an idle cache from another
    # client can still be cleaned.  Snapshot failure remains fail-closed.
    simplemole_path_open_state "$candidate" || state=$?
    [[ "$state" -eq 1 ]]
}

simplemole_install_delete_final_guard simplemole_ai_path_guard || {
    echo "error: could not install final AI-cache runtime guard"
    exit 1
}

while IFS= read -r -d '' path; do
    identity=""
    if ! IFS= read -r -d '' identity; then
        echo "error: missing identity for AI cleanup path: $path"
        failed=$((failed + 1))
        break
    fi
    if [[ -z "$path" || ! "$identity" =~ ^[0-9]+:[0-9]+:[0-9]+$ ]]; then
        failed=$((failed + 1))
        continue
    fi
    # A path outside the catalog is a benign stale/unsupported row and can be
    # skipped. A malformed or redirected path is an integrity failure and must
    # surface as failed so the caller cannot mistake a symlink escape for a
    # successful no-op.
    if ! simplemole_ai_path_is_physical "$path"; then
        failed=$((failed + 1))
        continue
    fi
    if ! is_allowed "$path"; then
        if simplemole_ai_path_is_protected "$path"; then
            failed=$((failed + 1))
        else
            skipped=$((skipped + 1))
        fi
        continue
    fi
    if is_path_whitelisted "$path"; then skipped=$((skipped + 1)); continue; fi
    current_identity=$("$STAT_BSD" -f%d:%i:%m "$path" 2>/dev/null || true)
    [[ "$current_identity" == "$identity" ]] || { failed=$((failed + 1)); continue; }
    # The complete runtime/content guard runs once at mole_delete's final edge.
    if mole_delete "$path" false "$identity"; then removed=$((removed + 1)); else failed=$((failed + 1)); fi
done

printf 'removed=%s\nskipped=%s\nfailed=%s\n' "$removed" "$skipped" "$failed"
[[ "$failed" -eq 0 ]]
