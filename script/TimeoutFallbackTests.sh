#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
    printf 'not ok - %s\n' "$1" >&2
    exit 1
}

pass() {
    printf 'ok - %s\n' "$1"
}

[[ -x /usr/bin/perl ]] || fail "Perl fallback is unavailable"

# Force the exact fallback used on a stock macOS installation without
# coreutils. Do not let a developer-installed gtimeout hide regressions.
export MO_TIMEOUT_INITIALIZED=1
export MO_TIMEOUT_BIN=""
export MO_TIMEOUT_PERL_BIN=/usr/bin/perl
# shellcheck disable=SC1091
source "$ROOT_DIR/vendor/mole/lib/core/timeout.sh"

set +e
run_with_timeout 2 /bin/sh -c 'exit 23'
status=$?
set -e
[[ "$status" -eq 23 ]] || fail "Perl fallback did not preserve child exit status"
pass "Perl fallback preserves child exit status"

start=$(/usr/bin/perl -MTime::HiRes=time -e 'printf "%.6f", time')
for _ in {1..20}; do
    run_with_timeout 2 /usr/bin/true || fail "short command failed"
done
finish=$(/usr/bin/perl -MTime::HiRes=time -e 'printf "%.6f", time')
elapsed=$(/usr/bin/awk -v start="$start" -v finish="$finish" \
    'BEGIN { printf "%.3f", finish - start }')
# The former fixed 100ms poll takes at least two seconds for this batch. Keep
# enough headroom for a loaded CI host while still detecting that regression.
/usr/bin/awk -v elapsed="$elapsed" 'BEGIN { exit !(elapsed < 1.5) }' ||
    fail "short-command polling regressed (${elapsed}s for 20 commands)"
pass "Perl fallback reaps short commands promptly (${elapsed}s for 20 commands)"

start=$(/usr/bin/perl -MTime::HiRes=time -e 'printf "%.6f", time')
set +e
run_with_timeout 0.15 /bin/sleep 5
status=$?
set -e
finish=$(/usr/bin/perl -MTime::HiRes=time -e 'printf "%.6f", time')
elapsed=$(/usr/bin/awk -v start="$start" -v finish="$finish" \
    'BEGIN { printf "%.3f", finish - start }')
[[ "$status" -eq 124 ]] || fail "Perl fallback did not return timeout status 124"
/usr/bin/awk -v elapsed="$elapsed" 'BEGIN { exit !(elapsed < 1.5) }' ||
    fail "Perl fallback timeout was not enforced promptly (${elapsed}s)"
pass "Perl fallback preserves timeout status and deadline (${elapsed}s)"

fixture_root=$(mktemp -d "${TMPDIR:-/tmp}/forgesweep-timeout-tests.XXXXXX") ||
    fail "could not create timeout fixture"
case "$fixture_root" in
    "${TMPDIR:-/tmp}"/forgesweep-timeout-tests.*) ;;
    *) fail "unsafe timeout fixture path" ;;
esac
owner_pid=""
child_pid=""
cleanup() {
    [[ "$owner_pid" =~ ^[0-9]+$ ]] && /bin/kill -KILL "$owner_pid" 2>/dev/null || true
    [[ "$child_pid" =~ ^[0-9]+$ ]] && /bin/kill -KILL "$child_pid" 2>/dev/null || true
    /bin/rm -rf -- "$fixture_root"
}
trap cleanup EXIT

# Killing the shell that owns the timeout helper must not orphan its command.
# This exercises the existing getppid owner-death path without changing its
# TERM/KILL or process-group behavior.
(
    run_with_timeout 30 /bin/sh -c '
        printf "%s\n" "$$" > "$1"
        while :; do /bin/sleep 1; done
    ' timeout-child "$fixture_root/child.pid"
) &
owner_pid=$!

for _ in {1..100}; do
    [[ -s "$fixture_root/child.pid" ]] && break
    /bin/sleep 0.01
done
[[ -s "$fixture_root/child.pid" ]] || fail "timed child did not start"
child_pid=$(<"$fixture_root/child.pid")
[[ "$child_pid" =~ ^[0-9]+$ ]] || fail "timed child PID is invalid"

/bin/kill -KILL "$owner_pid" 2>/dev/null || fail "could not terminate timeout owner"
wait "$owner_pid" 2>/dev/null || true
owner_pid=""
for _ in {1..100}; do
    if ! /bin/kill -0 "$child_pid" 2>/dev/null; then
        child_pid=""
        break
    fi
    /bin/sleep 0.02
done
[[ -z "$child_pid" ]] || fail "Perl fallback orphaned a child after owner death"
pass "Perl fallback preserves owner-death cleanup"

trap - EXIT
cleanup
