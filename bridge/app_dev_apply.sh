#!/bin/bash
# NUL-delimited path/identity pairs are bound at confirmation time.
set -euo pipefail

HOME_DIR="${HOME%/}"
[[ -n "$HOME_DIR" && "$HOME_DIR" != "/" ]] || {
    echo "error: invalid HOME for developer cleanup" >&2
    exit 2
}
allowed=(
    "$HOME_DIR/.npm" "$HOME_DIR/.bun/install/cache" "$HOME_DIR/Library/pnpm/store"
    "$HOME_DIR/Library/Caches/pnpm" "$HOME_DIR/.yarn/cache"
    "$HOME_DIR/Library/Caches/Yarn" "$HOME_DIR/.m2/repository" "$HOME_DIR/.gradle/caches"
    "$HOME_DIR/.gradle/daemon" "$HOME_DIR/Library/Caches/com.openai.chat"
    "$HOME_DIR/Library/Caches/com.anthropic.claudefordesktop" "$HOME_DIR/Library/Logs/Claude"
    "$HOME_DIR/Library/Caches/go-build" "$HOME_DIR/go/pkg/mod/cache" "$HOME_DIR/go/pkg/mod"
    "$HOME_DIR/.cargo/registry/cache" "$HOME_DIR/.cargo/git/db"
    "$HOME_DIR/.nuget/packages" "$HOME_DIR/Library/Caches/NuGet"
    "$HOME_DIR/Library/Caches/pip" "$HOME_DIR/.cache/pip" "$HOME_DIR/Library/Caches/pypoetry" "$HOME_DIR/.cache/uv"
    "$HOME_DIR/.composer/cache" "$HOME_DIR/Library/Caches/composer" "$HOME_DIR/.pub-cache"
    "$HOME_DIR/.cache/bazel" "$HOME_DIR/.cache/zig" "$HOME_DIR/Library/Caches/org.swift.swiftpm"
    "$HOME_DIR/Library/Caches/Homebrew/downloads" "$HOME_DIR/.hex/cache"
    "$HOME_DIR/.tnpm/_cacache" "$HOME_DIR/.tnpm/_logs"
    "$HOME_DIR/.cache/poetry" "$HOME_DIR/.cache/ruff" "$HOME_DIR/.cache/mypy"
    "$HOME_DIR/.pytest_cache" "$HOME_DIR/.jupyter/runtime"
    "$HOME_DIR/.rbenv/cache" "$HOME_DIR/.gem/specs" "$HOME_DIR/.bundle/cache"
    "$HOME_DIR/.cpan/build" "$HOME_DIR/.kube/cache"
    "$HOME_DIR/.aws/cli/cache" "$HOME_DIR/.config/gcloud/logs" "$HOME_DIR/.azure/logs"
    "$HOME_DIR/.cache/typescript" "$HOME_DIR/.cache/electron" "$HOME_DIR/.cache/node-gyp"
    "$HOME_DIR/.node-gyp" "$HOME_DIR/.turbo/cache" "$HOME_DIR/.vite/cache"
    "$HOME_DIR/.cache/vite" "$HOME_DIR/.cache/webpack" "$HOME_DIR/.parcel-cache"
    "$HOME_DIR/.cache/eslint" "$HOME_DIR/.cache/prettier"
    "$HOME_DIR/.android/build-cache" "$HOME_DIR/.android/cache"
    "$HOME_DIR/.cache/swift-package-manager"
    "$HOME_DIR/.expo/expo-go" "$HOME_DIR/.expo/android-apk-cache"
    "$HOME_DIR/.expo/ios-simulator-app-cache" "$HOME_DIR/.expo/native-modules-cache"
    "$HOME_DIR/.expo/schema-cache" "$HOME_DIR/.expo/template-cache"
    "$HOME_DIR/.expo/versions-cache" "$HOME_DIR/Library/Logs/JetBrains"
)
if command -v go >/dev/null 2>&1; then
    go_cache=$(go env GOCACHE 2>/dev/null || true)
    go_mod_cache=$(go env GOMODCACHE 2>/dev/null || true)
    [[ "$go_cache" == /* ]] && allowed+=("$go_cache")
    [[ "$go_mod_cache" == /* ]] && allowed+=("$go_mod_cache")
fi
if [[ -n "${CARGO_HOME:-}" && -d "$CARGO_HOME/registry/cache" ]]; then
    allowed+=("$CARGO_HOME/registry/cache")
fi
is_allowed() {
    local candidate="$1" item
    forgesweep_scan_path_is_physical "$candidate" || return 1
    forgesweep_scan_path_allowed "$candidate" || return 1
    for item in "${allowed[@]}"; do
        # The scanner may submit a concrete child path (for example an npm
        # cache shard) when the user expands a category. The old exact-match
        # check silently rejected those selected children, so the UI reported
        # a failed cleanup even though the root itself was allowlisted.
        [[ "$candidate" == "$item" || "$candidate" == "$item"/* ]] && return 0
    done
    return 1
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/core/common.sh"
source "$SCRIPT_DIR/bin/app_scan_access.sh"
source "$SCRIPT_DIR/bin/app_runtime_guard.sh"
export MOLE_CURRENT_COMMAND="clean"
simplemole_configure_delete_mode
load_mole_whitelist
removed=0
skipped=0
failed=0

simplemole_dev_path_guard() {
    local candidate="$1" owner="" state=0
    if [[ "${MOLE_TEST_MODE:-0}" == "1" && -n "${SIMPLEMOLE_TEST_FINAL_GUARD_LOG:-}" ]]; then
        printf 'developer\n' >> "$SIMPLEMOLE_TEST_FINAL_GUARD_LOG"
    fi
    forgesweep_scan_path_is_physical "$candidate" || return 1
    forgesweep_scan_path_allowed "$candidate" || return 1
    load_mole_whitelist
    is_path_whitelisted "$candidate" && return 1
    simplemole_execution_content_allowed "$candidate" || return 1
    case "$candidate" in
        "$HOME_DIR/Library/Caches/com.openai.chat"|\
        "$HOME_DIR/Library/Caches/com.openai.chat/"*|\
        "$HOME_DIR/Library/Caches/com.anthropic.claudefordesktop"|\
        "$HOME_DIR/Library/Caches/com.anthropic.claudefordesktop/"*)
            owner=$(simplemole_reverse_dns_cache_owner "$candidate") || return 1
            simplemole_bundle_identifier_state "$owner" || state=$?
            ;;
        "$HOME_DIR/Library/Logs/Claude"|"$HOME_DIR/Library/Logs/Claude/"*)
            simplemole_any_process_state Claude claude || state=$?
            ;;
        *)
            # A generic `node` process is not enough evidence that a shared
            # cache is being written.  Use the one captured lsof snapshot for
            # the selected subtree instead; this keeps active writes blocked
            # without hiding every developer cache behind an unrelated Node
            # dev server.
            simplemole_path_open_state "$candidate" || state=$?
            ;;
    esac
    [[ "$state" -eq 1 ]]
}

simplemole_install_delete_final_guard simplemole_dev_path_guard || {
    echo "error: could not install final developer-cache runtime guard"
    exit 1
}

while IFS= read -r -d '' path; do
    identity=""
    if ! IFS= read -r -d '' identity; then
        echo "error: missing identity for dev cleanup path: $path"
        failed=$((failed + 1))
        break
    fi
    if [[ -z "$path" || ! "$identity" =~ ^[0-9]+:[0-9]+:[0-9]+$ ]]; then
        failed=$((failed + 1))
        continue
    fi
    is_allowed "$path" || { failed=$((failed + 1)); continue; }
    if is_path_whitelisted "$path"; then skipped=$((skipped + 1)); continue; fi
    current_identity=$("$STAT_BSD" -f%d:%i:%m "$path" 2>/dev/null || true)
    [[ "$current_identity" == "$identity" ]] || { failed=$((failed + 1)); continue; }
    # The complete runtime/content guard runs once at mole_delete's final edge.
    if mole_delete "$path" false "$identity"; then removed=$((removed + 1)); else failed=$((failed + 1)); fi
done

printf 'removed=%s\nskipped=%s\nfailed=%s\n' "$removed" "$skipped" "$failed"
[[ "$failed" -eq 0 ]]
