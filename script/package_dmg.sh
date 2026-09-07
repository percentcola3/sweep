#!/usr/bin/env bash
# Build an open-source distributable DMG. By default the app is ad-hoc signed,
# which needs no Apple Developer certificate and is suitable for GitHub Releases.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
PACKAGE_NAME="${SM_PACKAGE_NAME:-ForgeSweep}"
REQUESTED_DMG_PATH="${SM_DMG_PATH:-}"
BUILD_ARCHS="${SM_BUILD_ARCHS:-arm64 x86_64}"

if [[ -n "$REQUESTED_DMG_PATH" ]]; then
    case "$BUILD_ARCHS" in
        arm64|x86_64) ;;
        *) echo "error: SM_DMG_PATH requires a single SM_BUILD_ARCHS architecture" >&2; exit 2 ;;
    esac
fi
# Ad-hoc signing is intentional for the open-source distribution path. A
# stable Apple Development or Developer ID identity can still be supplied.
SIGN_IDENTITY="${SM_CODESIGN_IDENTITY:--}"
ALLOW_ADHOC="${SM_ALLOW_ADHOC:-1}"
STAGE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/forgesweep-dmg.XXXXXX")"
trap 'rm -rf "$STAGE_ROOT"' EXIT

[[ "$(uname -s)" == "Darwin" ]] || {
    echo "error: DMG packaging requires macOS hdiutil" >&2
    exit 1
}
command -v hdiutil >/dev/null 2>&1 || {
    echo "error: hdiutil is required to create a DMG" >&2
    exit 1
}

SIGNING_LABEL="$SIGN_IDENTITY"
if [[ "$SIGN_IDENTITY" == "-" ]]; then
    SIGNING_LABEL="ad-hoc"
fi
echo "==> Building ForgeSweep for DMG ($SIGNING_LABEL)"
SM_BUILD_ARCHS="$BUILD_ARCHS" \
SM_CODESIGN_IDENTITY="$SIGN_IDENTITY" \
SM_ALLOW_ADHOC="$ALLOW_ADHOC" \
    bash "$ROOT_DIR/script/build.sh"

for arch in $BUILD_ARCHS; do
    APP_BUNDLE="$DIST_DIR/$arch/ForgeSweep.app"
    DMG_PATH="${REQUESTED_DMG_PATH:-$DIST_DIR/$PACKAGE_NAME-$arch.dmg}"
    [[ -d "$APP_BUNDLE" ]] || {
        echo "error: app bundle was not produced: $APP_BUNDLE" >&2
        exit 1
    }

    STAGE_DIR="$STAGE_ROOT/$arch"
    mkdir -p "$STAGE_DIR"
    /usr/bin/ditto "$APP_BUNDLE" "$STAGE_DIR/ForgeSweep.app"
    # Finder shows the conventional Applications shortcut alongside the App.
    ln -s /Applications "$STAGE_DIR/Applications"

    mkdir -p "$(dirname "$DMG_PATH")"
    rm -f "$DMG_PATH"
    /usr/bin/hdiutil create \
        -volname "$PACKAGE_NAME" \
        -srcfolder "$STAGE_DIR" \
        -ov \
        -format UDZO \
        "$DMG_PATH" >/dev/null
    /usr/bin/hdiutil imageinfo "$DMG_PATH" >/dev/null

    echo "Built $DMG_PATH"
done
if [[ "$SIGN_IDENTITY" == "-" ]]; then
    echo "warning: this DMG contains an ad-hoc signed App; macOS may require manual Gatekeeper approval" >&2
fi
