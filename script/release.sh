#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MOLE_SRC="${MOLE_SRC:-$ROOT_DIR/vendor/mole}"
MOLE_EXPECTED_COMMIT="${MOLE_EXPECTED_COMMIT:-}"
IDENTITY="${SM_CODESIGN_IDENTITY:?set SM_CODESIGN_IDENTITY to a Developer ID Application identity}"
NOTARY_PROFILE="${SM_NOTARY_PROFILE:?set SM_NOTARY_PROFILE to an xcrun notarytool keychain profile}"
BUILD_ARCHS="${SM_BUILD_ARCHS:-arm64 x86_64}"

if [[ "$IDENTITY" == "-" ]]; then
    echo "error: release builds require a Developer ID Application identity" >&2
    exit 2
fi

SIGNING_IDENTITIES=$(/usr/bin/security find-identity -p codesigning -v 2>/dev/null || true)
IDENTITY_RECORD=""
REQUESTED_IDENTITY_HASH=$(printf '%s' "$IDENTITY" | /usr/bin/tr '[:lower:]' '[:upper:]')
while IFS= read -r line; do
    [[ "$line" == *'"'* ]] || continue
    record_hash=$(printf '%s\n' "$line" | /usr/bin/awk '{print $2}')
    if [[ "$IDENTITY" =~ ^[0-9A-Fa-f]{40}$ ]]; then
        record_hash=$(printf '%s' "$record_hash" | /usr/bin/tr '[:lower:]' '[:upper:]')
        [[ "$record_hash" == "$REQUESTED_IDENTITY_HASH" ]] || continue
    else
        [[ "$line" == *"\"$IDENTITY\""* ]] || continue
    fi
    IDENTITY_RECORD="$line"
    break
done <<< "$SIGNING_IDENTITIES"
[[ -n "$IDENTITY_RECORD" ]] || {
    echo "error: requested release signing identity is not available: $IDENTITY" >&2
    exit 2
}
[[ "$IDENTITY_RECORD" == *'"Developer ID Application: '* ]] || {
    echo "error: release builds require a Developer ID Application certificate" >&2
    exit 2
}

if [[ ! -d "$MOLE_SRC" ]]; then
    echo "error: Mole source not found at $MOLE_SRC" >&2
    exit 2
fi
MOLE_SRC="$(cd "$MOLE_SRC" && pwd -P)"

verify_mole_source() {
    local actual_commit status
    if [[ -f "$MOLE_SRC/UPSTREAM_COMMIT" ]]; then
        actual_commit=$(< "$MOLE_SRC/UPSTREAM_COMMIT")
    else
        actual_commit=$(/usr/bin/git -C "$MOLE_SRC" rev-parse --verify 'HEAD^{commit}' 2>/dev/null) || {
            echo "error: Mole source has neither UPSTREAM_COMMIT nor Git metadata" >&2
            exit 2
        }
        status=$(/usr/bin/git -C "$MOLE_SRC" status --porcelain=v1 \
            --untracked-files=all --ignore-submodules=none)
        if [[ -n "$status" ]]; then
            echo "error: external Mole checkout must be clean" >&2
            exit 2
        fi
    fi
    if [[ -n "$MOLE_EXPECTED_COMMIT" && "$actual_commit" != "$MOLE_EXPECTED_COMMIT" ]]; then
        echo "error: Mole HEAD does not match MOLE_EXPECTED_COMMIT" >&2
        echo "expected: $MOLE_EXPECTED_COMMIT" >&2
        echo "actual:   $actual_commit" >&2
        exit 2
    fi
}

verify_mole_source
MOLE_SRC="$MOLE_SRC" SM_TEST_SKIP_SWIFT=0 SM_TEST_BUILD=0 \
    bash "$ROOT_DIR/script/test.sh"
# Tests are read-only for Mole, but repeat the pin and cleanliness check to
# close the window before build.sh copies and signs the dependency.
verify_mole_source

MOLE_SRC="$MOLE_SRC" SM_BUILD_ARCHS="$BUILD_ARCHS" SM_CODESIGN_IDENTITY="$IDENTITY" \
    SM_ALLOW_ADHOC=0 \
    bash "$ROOT_DIR/script/build.sh"

for arch in $BUILD_ARCHS; do
    APP_BUNDLE="$ROOT_DIR/dist/$arch/ForgeSweep.app"
    NOTARY_ARCHIVE="$ROOT_DIR/dist/ForgeSweep-$arch-notarization.zip"
    DISTRIBUTION_ARCHIVE="$ROOT_DIR/dist/ForgeSweep-$arch.zip"
    /usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
    RELEASE_SIGN_DETAILS=$(/usr/bin/codesign -dvvv "$APP_BUNDLE" 2>&1)
    printf '%s\n' "$RELEASE_SIGN_DETAILS" | /usr/bin/grep -Fq 'Authority=Developer ID Application:' || {
        echo "error: release App is not signed with Developer ID Application" >&2
        exit 2
    }
    /bin/rm -f "$NOTARY_ARCHIVE" "$DISTRIBUTION_ARCHIVE"
    /usr/bin/ditto -c -k --keepParent "$APP_BUNDLE" "$NOTARY_ARCHIVE"
    /usr/bin/xcrun notarytool submit "$NOTARY_ARCHIVE" --keychain-profile "$NOTARY_PROFILE" --wait
    /usr/bin/xcrun stapler staple "$APP_BUNDLE"
    /usr/sbin/spctl -a -vv --type execute "$APP_BUNDLE"
    /usr/bin/ditto -c -k --keepParent "$APP_BUNDLE" "$DISTRIBUTION_ARCHIVE"

    echo "Release archive is signed, notarized, and stapled: $DISTRIBUTION_ARCHIVE"
done
