#!/bin/bash
# App bridge: available official GC commands. Read-only.
# TSV: id \t command \t cache_bytes — the run bridge whitelists the same id table.
set -euo pipefail

cache_bytes() {
    local path size total=0
    for path in "$@"; do
        [[ -d "$path" ]] || continue
        size=$(du -sk "$path" 2>/dev/null | awk '{print $1 * 1024}')
        [[ "$size" =~ ^[0-9]+$ ]] || size=0
        total=$((total + size))
    done
    printf '%s' "$total"
}

emit() {
    local id="$1" executable="$2" display="$3"
    shift 3
    command -v "$executable" >/dev/null 2>&1 || return 0
    printf '%s\t%s\t%s\n' "$id" "$display" "$(cache_bytes "$@")"
}

emit brew  brew  "brew cleanup --prune=all"
emit npm   npm   "npm cache clean --force" "$HOME/.npm"
emit pnpm  pnpm  "pnpm store prune" "$HOME/Library/pnpm/store"
emit yarn  yarn  "yarn cache clean" "$HOME/.yarn/cache" "$HOME/Library/Caches/Yarn"
emit bun   bun   "bun pm cache rm"
emit pip   pip   "pip cache purge"
emit pip3  pip3  "pip3 cache purge"
emit uv    uv    "uv cache clean"
emit conda conda "conda clean --all -y"
emit gem   gem   "gem cleanup"
emit deno  deno  "deno clean"
emit go-build go "go clean -cache"
emit go-mod   go "go clean -modcache"

# Docker prune（守护进程不可达时运行会快速失败并计入失败，不影响其他条目）
emit docker-builder docker "docker builder prune -f"
emit docker-system  docker "docker system prune -f"

# Xcode 模拟器孤儿设备清理
if command -v xcrun >/dev/null 2>&1 && xcrun --find simctl >/dev/null 2>&1; then
    printf 'simctl\txcrun simctl delete unavailable\t0\n'
fi
