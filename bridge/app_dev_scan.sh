#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/core/common.sh"
# Keep the developer inventory on the same permission boundary as every other
# bridge. Explicit cache leaves below are user-owned and normally enumerate
# without FDA; any future protected root is skipped until Swift verifies FDA.
source "$SCRIPT_DIR/bin/app_scan_access.sh"
load_mole_whitelist

HOME_DIR="${HOME%/}"
[[ -n "$HOME_DIR" && "$HOME_DIR" != "/" ]] || exit 0
declare -a candidates=(
    "$HOME_DIR/.npm|npm 缓存"
    "$HOME_DIR/.bun/install/cache|Bun 缓存"
    "$HOME_DIR/Library/pnpm/store|pnpm 缓存"
    "$HOME_DIR/Library/Caches/pnpm|pnpm 缓存"
    "$HOME_DIR/.yarn/cache|Yarn 缓存"
    "$HOME_DIR/Library/Caches/Yarn|Yarn v1 缓存"
    "$HOME_DIR/.m2/repository|Maven 本地仓库"
    "$HOME_DIR/.gradle/caches|Gradle 缓存"
    "$HOME_DIR/.gradle/daemon|Gradle Daemon 缓存"
    "$HOME_DIR/Library/Caches/go-build|Go 编译缓存"
    "$HOME_DIR/go/pkg/mod|Go 模块缓存"
    "$HOME_DIR/.cargo/registry/cache|Rust Cargo 注册表缓存"
    "$HOME_DIR/.cargo/git/db|Rust Cargo Git 缓存"
    "$HOME_DIR/.nuget/packages|.NET NuGet 全局包缓存"
    "$HOME_DIR/Library/Caches/NuGet|.NET NuGet 缓存"
    "$HOME_DIR/Library/Caches/pip|Python pip 缓存"
    "$HOME_DIR/.cache/pip|Python pip 缓存"
    "$HOME_DIR/Library/Caches/pypoetry|Python Poetry 缓存"
    "$HOME_DIR/.cache/uv|Python uv 缓存"
    "$HOME_DIR/.composer/cache|PHP Composer 缓存"
    "$HOME_DIR/Library/Caches/composer|PHP Composer 缓存"
    "$HOME_DIR/.pub-cache|Dart Pub 缓存"
    "$HOME_DIR/.cache/bazel|Bazel 缓存"
    "$HOME_DIR/.cache/zig|Zig 缓存"
    "$HOME_DIR/Library/Caches/org.swift.swiftpm|Swift Package Manager 缓存"
    "$HOME_DIR/Library/Caches/Homebrew/downloads|Homebrew 下载缓存"
    "$HOME_DIR/.hex/cache|Elixir Hex 缓存"
    "$HOME_DIR/.tnpm/_cacache|tnpm 缓存"
    "$HOME_DIR/.tnpm/_logs|tnpm 日志"
    "$HOME_DIR/.cache/poetry|Poetry 缓存"
    "$HOME_DIR/.cache/ruff|Ruff 缓存"
    "$HOME_DIR/.cache/mypy|MyPy 缓存"
    "$HOME_DIR/.pytest_cache|Pytest 缓存"
    "$HOME_DIR/.jupyter/runtime|Jupyter 运行时缓存"
    "$HOME_DIR/.rbenv/cache|rbenv 下载缓存"
    "$HOME_DIR/.gem/specs|Ruby gem spec 缓存"
    "$HOME_DIR/.bundle/cache|Bundler 缓存"
    "$HOME_DIR/.cpan/build|CPAN 构建缓存"
    "$HOME_DIR/.kube/cache|Kubernetes 缓存"
    "$HOME_DIR/.aws/cli/cache|AWS CLI 缓存"
    "$HOME_DIR/.config/gcloud/logs|Google Cloud 日志"
    "$HOME_DIR/.azure/logs|Azure CLI 日志"
    "$HOME_DIR/.cache/typescript|TypeScript 缓存"
    "$HOME_DIR/.cache/electron|Electron 缓存"
    "$HOME_DIR/.cache/node-gyp|node-gyp 缓存"
    "$HOME_DIR/.node-gyp|node-gyp 构建缓存"
    "$HOME_DIR/.turbo/cache|Turbo 缓存"
    "$HOME_DIR/.vite/cache|Vite 缓存"
    "$HOME_DIR/.cache/vite|Vite 全局缓存"
    "$HOME_DIR/.cache/webpack|Webpack 缓存"
    "$HOME_DIR/.parcel-cache|Parcel 缓存"
    "$HOME_DIR/.cache/eslint|ESLint 缓存"
    "$HOME_DIR/.cache/prettier|Prettier 缓存"
    "$HOME_DIR/.android/build-cache|Android 构建缓存"
    "$HOME_DIR/.android/cache|Android SDK 缓存"
    "$HOME_DIR/.cache/swift-package-manager|Swift 包管理器缓存"
    "$HOME_DIR/.expo/expo-go|Expo Go 缓存"
    "$HOME_DIR/.expo/android-apk-cache|Expo Android APK 缓存"
    "$HOME_DIR/.expo/ios-simulator-app-cache|Expo iOS 模拟器缓存"
    "$HOME_DIR/.expo/native-modules-cache|Expo 原生模块缓存"
    "$HOME_DIR/.expo/schema-cache|Expo schema 缓存"
    "$HOME_DIR/.expo/template-cache|Expo 模板缓存"
    "$HOME_DIR/.expo/versions-cache|Expo 版本缓存"
    "$HOME_DIR/Library/Logs/JetBrains|JetBrains IDE 日志"
    "$HOME_DIR/Library/Caches/com.openai.chat|ChatGPT 缓存"
    "$HOME_DIR/Library/Caches/com.anthropic.claudefordesktop|Claude Desktop 缓存"
    "$HOME_DIR/Library/Logs/Claude|Claude 日志"
    # AI-owned caches use a separate scanner with narrower, audited leaf
    # allowlists. Do not surface their whole browser-profile parents here.
)

declare -a emitted_paths=()
declare -a candidate_paths=()
declare -a candidate_names=()
emit_candidate() {
    local path="${1:-}" name="${2:-}" existing=""
    forgesweep_scan_path_is_physical "$path" || return 0
    forgesweep_scan_path_allowed "$path" || return 0
    [[ -e "$path" && ! -L "$path" ]] || return 0
    is_path_whitelisted "$path" && return 0
    if [[ ${#emitted_paths[@]} -gt 0 ]]; then
        for existing in "${emitted_paths[@]}"; do
            # A scanner record owns one physical subtree. Exact duplicates and
            # parent/child overlaps would otherwise be counted and deleted twice.
            if [[ "$path" == "$existing" || "$path" == "$existing/"* ||
                  "$existing" == "$path/"* ]]; then
                return 0
            fi
        done
    fi
    # Defer sizing until all candidates are known. Most cache roots are
    # ordinary paths, so one batched `du` invocation avoids starting a
    # subprocess for every tool. Paths containing a tab/newline are kept in
    # the queue too and use the old single-path fallback below; this keeps
    # arbitrary POSIX path names safe without weakening the scanner boundary.
    candidate_paths+=("$path")
    candidate_names+=("$name")
    emitted_paths+=("$path")
}

for entry in "${candidates[@]}"; do
    path="${entry%%|*}"; name="${entry#*|}"
    emit_candidate "$path" "$name"
done

# Respect user-configured cache locations without deleting arbitrary toolchains.
if command -v go >/dev/null 2>&1; then
    go_cache=$(go env GOCACHE 2>/dev/null || true)
    go_mod_cache=$(go env GOMODCACHE 2>/dev/null || true)
    emit_candidate "$go_cache" "Go 编译缓存（当前配置）"
    emit_candidate "$go_mod_cache" "Go 模块缓存（当前配置）"
fi
if [[ -n "${CARGO_HOME:-}" && -d "$CARGO_HOME/registry/cache" ]]; then
    emit_candidate "$CARGO_HOME/registry/cache" "Rust Cargo 注册表缓存（当前配置）"
fi

# Measure queued roots in one pass. `du -P` prints one tab-delimited total per
# argument; retain the reported path and match it exactly so spaces remain
# valid. A partial/failed batch is still useful: any root missing from its
# output is retried with the original single-path probe, preserving the prior
# fail-closed behavior for permission races and disappearing caches.
declare -a batch_paths=()
for path in "${candidate_paths[@]+"${candidate_paths[@]}"}"; do
    if [[ "$path" == *$'\n'* || "$path" == *$'\t'* ]]; then
        continue
    fi
    batch_paths+=("$path")
done

du_output=""
if [[ ${#batch_paths[@]} -gt 0 ]]; then
    du_batch_status=0
    du_output=$(du -skP "${batch_paths[@]}" 2>/dev/null) || du_batch_status=$?
fi

declare -a sized_paths=()
declare -a sized_bytes=()
if [[ -n "$du_output" ]]; then
    while IFS=$'\t' read -r size_kb reported_path; do
        [[ "$size_kb" =~ ^[0-9]+$ && -n "$reported_path" ]] || continue
        sized_paths+=("$reported_path")
        sized_bytes+=("$((size_kb * 1024))")
    done <<< "$du_output"
fi

for ((candidate_index = 0; candidate_index < ${#candidate_paths[@]}; candidate_index++)); do
    path="${candidate_paths[$candidate_index]}"
    name="${candidate_names[$candidate_index]}"
    bytes=""

    # Newline/tab paths were intentionally excluded from the batch because
    # `du` has no portable NUL-delimited output mode. They are rare (none of
    # the built-in roots use them) but retain exact legacy handling.
    if [[ "$path" == *$'\n'* || "$path" == *$'\t'* ]]; then
        bytes=$(du -skP "$path" 2>/dev/null | awk '{print $1 * 1024}')
    else
        for ((size_index = 0; size_index < ${#sized_paths[@]}; size_index++)); do
            if [[ "${sized_paths[$size_index]}" == "$path" ]]; then
                bytes="${sized_bytes[$size_index]}"
                break
            fi
        done
        # A failed batch (or a path removed during the scan) falls back to
        # one exact probe, matching the previous behavior.
        if [[ -z "$bytes" ]]; then
            bytes=$(du -skP "$path" 2>/dev/null | awk '{print $1 * 1024}')
        fi
    fi

    [[ "$bytes" =~ ^[0-9]+$ ]] || bytes=0
    [[ "$bytes" -gt 0 ]] || continue
    printf '%s\t%s\t%s\n' "$bytes" "$name" "$path"
done
