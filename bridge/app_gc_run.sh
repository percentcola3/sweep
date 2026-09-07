#!/bin/bash
# App bridge: run ONE whitelisted official GC command.
# Usage: app_gc_run.sh <id>  — the id must exist in this table; everything
# else is refused, so the GUI can never execute an arbitrary command line.
set -euo pipefail

id="${1:-}"
case "$id" in
    brew)     cmd=(brew cleanup --prune=all);;
    npm)      cmd=(npm cache clean --force);;
    pnpm)     cmd=(pnpm store prune);;
    yarn)     cmd=(yarn cache clean);;
    bun)      cmd=(bun pm cache rm);;
    pip)      cmd=(pip cache purge);;
    pip3)     cmd=(pip3 cache purge);;
    uv)       cmd=(uv cache clean);;
    conda)    cmd=(conda clean --all -y);;
    gem)      cmd=(gem cleanup);;
    deno)     cmd=(deno clean);;
    go-build) cmd=(go clean -cache);;
    go-mod)   cmd=(go clean -modcache);;
    docker-builder) cmd=(docker builder prune -f);;
    docker-system)  cmd=(docker system prune -f);;
    simctl)   cmd=(xcrun simctl delete unavailable);;
    *)
        echo "unknown gc id: $id" >&2
        exit 2
        ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1090
source "$SCRIPT_DIR/lib/core/common.sh"
export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ENV_HINTS=1 NONINTERACTIVE=1
run_with_timeout 900 "${cmd[@]}"
