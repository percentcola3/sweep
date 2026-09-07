#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="ForgeSweep"
BUNDLE_ID="com.forgesweep.app"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_ARCH="${SM_BUILD_ARCHS:-$(uname -m)}"
case "$RUN_ARCH" in
    arm64|x86_64) ;;
    *) echo "error: build_and_run.sh requires one architecture; use package_dmg.sh to build both" >&2; exit 2 ;;
esac
APP_BUNDLE="$ROOT_DIR/dist/$RUN_ARCH/ForgeSweep.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"

pkill -x "$APP_NAME" >/dev/null 2>&1 || true
SM_BUILD_ARCHS="$RUN_ARCH" \
SM_CODESIGN_IDENTITY="${SM_CODESIGN_IDENTITY:-}" \
SM_ALLOW_ADHOC="${SM_ALLOW_ADHOC:-0}" \
    bash "$ROOT_DIR/script/build.sh"

open_app() {
    /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
    run)
        open_app
        ;;
    --debug|debug)
        /usr/bin/lldb -- "$APP_BINARY"
        ;;
    --logs|logs)
        open_app
        /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
        ;;
    --telemetry|telemetry)
        open_app
        /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
        ;;
    --verify|verify)
        open_app
        sleep 1
        pgrep -x "$APP_NAME" >/dev/null
        ;;
    *)
        echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
        exit 2
        ;;
esac
