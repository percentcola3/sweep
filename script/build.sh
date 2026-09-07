#!/usr/bin/env bash
# Build ForgeSweep.app: compile the Swift UI layer, then bundle only the
# vendored shell libraries still used by optional bridge features.  The five
# core operations are implemented by Swift and do not ship or invoke Mole's
# command router or Go helpers.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MOLE_SRC="${MOLE_SRC:-$ROOT_DIR/vendor/mole}"
BUILD_ARCHS="${SM_BUILD_ARCHS:-$(uname -m)}"
REQUESTED_SIGN_IDENTITY="${SM_CODESIGN_IDENTITY:-}"
ALLOW_ADHOC="${SM_ALLOW_ADHOC:-0}"
SIGN_IDENTITY=""
SIGN_IDENTITY_LABEL=""
SIGN_IDENTITY_KIND=""
BUILD_TMP="$(mktemp -d "${TMPDIR:-/tmp}/forgesweep-build.XXXXXX")"
trap 'rm -rf "$BUILD_TMP"' EXIT

# Validate the whole request before replacing any existing architecture bundle.
for arch in $BUILD_ARCHS; do
    case "$arch" in
        arm64|x86_64) ;;
        *) echo "error: unsupported architecture: $arch" >&2; exit 2 ;;
    esac
done

case "$ALLOW_ADHOC" in
    0|1) ;;
    *) echo "error: SM_ALLOW_ADHOC must be 0 or 1" >&2; exit 2 ;;
esac

SIGNING_IDENTITIES=$(/usr/bin/security find-identity -p codesigning -v 2>/dev/null || true)

identity_record_for() {
    local requested="$1" line="" record_hash="" requested_hash=""
    requested_hash=$(printf '%s' "$requested" | /usr/bin/tr '[:lower:]' '[:upper:]')
    while IFS= read -r line; do
        [[ "$line" == *'"'* ]] || continue
        record_hash=$(printf '%s\n' "$line" | /usr/bin/awk '{print $2}')
        if [[ "$requested" =~ ^[0-9A-Fa-f]{40}$ ]]; then
            record_hash=$(printf '%s' "$record_hash" | /usr/bin/tr '[:lower:]' '[:upper:]')
            [[ "$record_hash" == "$requested_hash" ]] || continue
        else
            [[ "$line" == *"\"$requested\""* ]] || continue
        fi
        printf '%s\n' "$line"
        return 0
    done <<< "$SIGNING_IDENTITIES"
    return 1
}

set_signing_identity_from_record() {
    local record="$1" requested="${2:-}" label=""
    label="${record#*\"}"
    label="${label%%\"*}"
    case "$label" in
        "Apple Development: "*) SIGN_IDENTITY_KIND="development" ;;
        "Developer ID Application: "*) SIGN_IDENTITY_KIND="developer-id" ;;
        *)
            echo "error: unsupported signing identity: $label" >&2
            echo "Use Apple Development for local builds or Developer ID Application for releases." >&2
            exit 2
            ;;
    esac
    SIGN_IDENTITY_LABEL="$label"
    SIGN_IDENTITY="${requested:-$label}"
}

resolve_signing_identity() {
    local record="" line=""
    if [[ "$REQUESTED_SIGN_IDENTITY" == "-" ]]; then
        [[ "$ALLOW_ADHOC" == "1" ]] || {
            echo "error: ad-hoc signing requires explicit SM_ALLOW_ADHOC=1" >&2
            exit 2
        }
        SIGN_IDENTITY="-"
        SIGN_IDENTITY_LABEL="ad-hoc"
        SIGN_IDENTITY_KIND="adhoc"
        return
    fi

    if [[ -n "$REQUESTED_SIGN_IDENTITY" ]]; then
        record=$(identity_record_for "$REQUESTED_SIGN_IDENTITY") || {
            echo "error: requested code-signing identity is not available: $REQUESTED_SIGN_IDENTITY" >&2
            exit 2
        }
        set_signing_identity_from_record "$record" "$REQUESTED_SIGN_IDENTITY"
        return
    fi

    while IFS= read -r line; do
        if [[ "$line" == *'"Apple Development: '* ]]; then
            set_signing_identity_from_record "$line"
            return
        fi
    done <<< "$SIGNING_IDENTITIES"

    if [[ "$ALLOW_ADHOC" == "1" ]]; then
        SIGN_IDENTITY="-"
        SIGN_IDENTITY_LABEL="ad-hoc"
        SIGN_IDENTITY_KIND="adhoc"
        return
    fi

    echo "error: no Apple Development signing identity is available" >&2
    echo "Install an Apple Development certificate or use SM_ALLOW_ADHOC=1 only for CI/tests." >&2
    echo "Ad-hoc GUI builds do not provide a stable identity for macOS privacy grants." >&2
    exit 2
}

resolve_signing_identity
echo "==> Signing mode: $SIGN_IDENTITY_LABEL"

if [[ ! -d "$MOLE_SRC/lib" ]]; then
    echo "error: vendored bridge support libraries not found at $MOLE_SRC" >&2
    exit 1
fi

sign_one() {
    local target="$1"
    if [[ "$SIGN_IDENTITY_KIND" == "adhoc" ]]; then
        /usr/bin/codesign --force --sign - "$target" >/dev/null
    elif [[ "$SIGN_IDENTITY_KIND" == "developer-id" ]]; then
        /usr/bin/codesign --force --options runtime --timestamp \
            --sign "$SIGN_IDENTITY" "$target"
    else
        /usr/bin/codesign --force --options runtime --timestamp=none \
            --sign "$SIGN_IDENTITY" "$target"
    fi
}

# Keep each architecture in its own bundle; local builds default to this Mac.
for arch in $BUILD_ARCHS; do
    APP_DIR="$ROOT_DIR/dist/$arch/ForgeSweep.app"
    CONTENTS="$APP_DIR/Contents"
    RESOURCES="$CONTENTS/Resources"
    rm -rf "$APP_DIR"
    mkdir -p "$CONTENTS/MacOS" "$RESOURCES"

    echo "==> Compiling Swift app ($arch)"
    swiftc -O -whole-module-optimization -target "$arch-apple-macos13.0" \
        -module-cache-path "$BUILD_TMP/module-cache-$arch" \
        -framework Cocoa -framework SwiftUI -framework Security -framework CryptoKit -framework IOKit \
        "$ROOT_DIR"/SimpleMole/*.swift \
        "$ROOT_DIR"/SimpleMole/L10n/*.swift \
        "$ROOT_DIR"/SimpleMole/Services/*.swift \
        "$ROOT_DIR"/SimpleMole/Views/*.swift \
        -o "$CONTENTS/MacOS/ForgeSweep"

    [[ "$(/usr/bin/lipo -archs "$CONTENTS/MacOS/ForgeSweep")" == "$arch" ]] || {
        echo "error: expected a single $arch executable" >&2
        exit 2
    }

    # Remove local symbols before signing this architecture's executable.
    /usr/bin/strip -x "$CONTENTS/MacOS/ForgeSweep"

    cp "$ROOT_DIR/SimpleMole/Support/Info.plist" "$CONTENTS/Info.plist"

    echo "==> Bundling bridge support libraries from $MOLE_SRC"
    bash "$ROOT_DIR/script/stage_bridge_resources.sh" "$MOLE_SRC" "$RESOURCES"

    if [[ -f "$ROOT_DIR/SimpleMole/Support/AppIcon.icns" ]]; then
        cp "$ROOT_DIR/SimpleMole/Support/AppIcon.icns" "$RESOURCES/AppIcon.icns"
    fi
    if [[ -f "$ROOT_DIR/SimpleMole/Support/HeaderBrandIcon.png" ]]; then
        cp "$ROOT_DIR/SimpleMole/Support/HeaderBrandIcon.png" "$RESOURCES/HeaderBrandIcon.png"
    fi
    if [[ -f "$ROOT_DIR/SimpleMole/Support/MenuBarIconTemplate.png" ]]; then
        cp "$ROOT_DIR/SimpleMole/Support/MenuBarIconTemplate.png" "$RESOURCES/MenuBarIconTemplate.png"
    fi

    # Resources contain only shell scripts and images, with no nested executables.
    sign_one "$CONTENTS/MacOS/ForgeSweep"
    sign_one "$APP_DIR"
    /usr/bin/codesign --verify --deep --strict "$APP_DIR"

    SIGN_DETAILS=$(/usr/bin/codesign -dvvv "$APP_DIR" 2>&1)
    if [[ "$SIGN_IDENTITY_KIND" == "adhoc" ]]; then
        printf '%s\n' "$SIGN_DETAILS" | /usr/bin/grep -Fq 'Signature=adhoc' || {
            echo "error: expected an explicitly allowed ad-hoc signature" >&2
            exit 2
        }
        echo "warning: ad-hoc signature was explicitly allowed for CI/tests; do not use this build to validate macOS permission persistence" >&2
    else
        printf '%s\n' "$SIGN_DETAILS" | /usr/bin/grep -Fq "Authority=$SIGN_IDENTITY_LABEL" || {
            echo "error: built App is not signed by the resolved identity: $SIGN_IDENTITY_LABEL" >&2
            exit 2
        }
        TEAM_IDENTIFIER=$(printf '%s\n' "$SIGN_DETAILS" | /usr/bin/sed -n 's/^TeamIdentifier=//p' | /usr/bin/head -n 1)
        [[ -n "$TEAM_IDENTIFIER" && "$TEAM_IDENTIFIER" != "not set" ]] || {
            echo "error: stable Apple signature is missing a TeamIdentifier" >&2
            exit 2
        }
        DESIGNATED_REQUIREMENT=$(/usr/bin/codesign -dr - "$APP_DIR" 2>&1) || {
            echo "error: could not read the App designated requirement" >&2
            exit 2
        }
        [[ -n "$DESIGNATED_REQUIREMENT" ]] || {
            echo "error: App designated requirement is empty" >&2
            exit 2
        }
        echo "==> Signed identity: $SIGN_IDENTITY_LABEL"
        echo "==> Team identifier: $TEAM_IDENTIFIER"
        echo "==> $DESIGNATED_REQUIREMENT"
    fi

    echo "Built $APP_DIR"
done
