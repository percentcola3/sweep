#!/usr/bin/env bash
# Source-level lifecycle regression: do not launch the app or scan the real home.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_STATE="$ROOT_DIR/SimpleMole/AppState.swift"
APP_DELEGATE="$ROOT_DIR/SimpleMole/AppDelegate.swift"
CLEANUP_VIEW="$ROOT_DIR/SimpleMole/Views/CleanupTabView.swift"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

if /usr/bin/grep -Eq 'scheduleCleanupWarmup|prewarmCleanupCacheIfNeeded|cleanupWarmup' \
    "$APP_STATE" "$APP_DELEGATE"; then
    fail "cleanup lifecycle still schedules automatic scans or retries"
fi

activation=$(/usr/bin/awk '
    /^    func refreshAuthorizationAndResume\(/ { capture = 1 }
    capture { print }
    capture && /^    }/ { exit }
' "$APP_STATE")
[[ -n "$activation" ]] || fail "authorization activation hook is missing"
if /usr/bin/grep -Eq 'scanCleanup\(|unifiedCleanupScan\(|quickOptimize\(' <<< "$activation"; then
    fail "activation starts a cleanup scan without a user request"
fi
/usr/bin/grep -Fq 'guard hasPendingPermissionAction else { return }' <<< "$activation" || \
    fail "activation does not gate resumption on an explicit pending action"
/usr/bin/grep -Fq 'resumePendingAuthorizedOperation()' <<< "$activation" || \
    fail "user-requested scan cannot resume after authorization"

cleanup_tab=$(/usr/bin/awk '
    /switch pages\[tab\]/ { capture = 1 }
    capture && /case \.cleanup:/ { cleanup = 1; next }
    cleanup && /case / { exit }
    cleanup && !/^[[:space:]]*\/\// && /[^[:space:]]/ { print $1 }
' "$APP_STATE")
[[ "$cleanup_tab" == "break" ]] || fail "cleanup tab activation mutates results or starts work"

/usr/bin/grep -Fq 'state.requestScanAccess(.quickOptimize)' "$CLEANUP_VIEW" || \
    fail "manual quick scan button is missing"
/usr/bin/grep -Fq 'state.requestScanAccess(.deepCleanupScan)' "$CLEANUP_VIEW" || \
    fail "manual deep scan button is missing"
/usr/bin/grep -Fq 'scanCleanup(force: true, mode: .quick)' "$APP_STATE" || \
    fail "manual quick scan does not request a fresh scan"
/usr/bin/grep -Fq 'if mode == .quick && scan.cacheable { CleanupCache.save(scan.categories) }' \
    "$APP_STATE" || fail "successful manual scans are no longer cached"

printf 'PASS: cleanup is manual; tab activation preserves results; pending authorization still resumes\n'
