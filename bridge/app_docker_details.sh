#!/bin/bash
# Read-only Docker inventory. stdout: kind<TAB>one Docker JSON template row.
set -euo pipefail
export LC_ALL=C

[[ "$#" -eq 1 ]] || { echo "usage: app_docker_details.sh <kind>" >&2; exit 2; }
kind="$1"

DOCKER_BIN=""
if [[ "${MOLE_TEST_MODE:-0}" == "1" && -n "${MOLE_TEST_DOCKER_BIN:-}" ]]; then
    DOCKER_BIN="$MOLE_TEST_DOCKER_BIN"
else
    DOCKER_BIN=$(command -v docker 2>/dev/null || true)
fi
if [[ -z "$DOCKER_BIN" || ! -x "$DOCKER_BIN" ]]; then
    echo "Docker CLI is unavailable." >&2
    exit 127
fi

case "$kind" in
    images)
        command_args=(image ls --all --no-trunc --format '{{json .}}')
        ;;
    containers)
        command_args=(container ls --all --no-trunc --size --format '{{json .}}')
        ;;
    volumes)
        command_args=(volume ls --format '{{json .}}')
        ;;
    build-cache)
        command_args=(builder du --format '{{json .}}')
        ;;
    *)
        echo "unknown Docker inventory kind: $kind" >&2
        exit 2
        ;;
esac

"$DOCKER_BIN" "${command_args[@]}" | while IFS= read -r row; do
    [[ -n "$row" ]] || continue
    printf '%s\t%s\n' "$kind" "$row"
done
