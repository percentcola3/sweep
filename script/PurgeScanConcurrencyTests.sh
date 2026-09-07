#!/usr/bin/env bash
# Regression test for the bounded root-level concurrency in app_purge_scan.sh.
# The fixture is entirely disposable; no real user paths or GUI are touched.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -x /usr/bin/perl ]] || { echo "not ok - Perl timing helper is unavailable" >&2; exit 1; }

TEST_TMP_BASE=$(cd -P "${TMPDIR:-/tmp}" && /bin/pwd -P)
TEST_ROOT=$(mktemp -d "$TEST_TMP_BASE/simple-mole-purge-scan-tests.XXXXXX")
TEST_ROOT=$(cd -P "$TEST_ROOT" && /bin/pwd -P)
case "$TEST_ROOT" in
    "$TEST_TMP_BASE"/simple-mole-purge-scan-tests.*) ;;
    *) echo "not ok - unsafe test fixture path" >&2; exit 1 ;;
esac

cleanup() {
    rm -rf -- "$TEST_ROOT"
}
trap cleanup EXIT

TEST_HOME="$TEST_ROOT/home"
TEST_CACHE="$TEST_ROOT/cache"
TOOL_BIN="$TEST_ROOT/tools"
TEST_TRASH="$TEST_HOME/.Trash"
IDLE_LSOF="$TEST_ROOT/lsof-idle"
STAGE="$TEST_ROOT/stage"
mkdir -p "$TEST_HOME/.config/mole" "$TEST_CACHE" "$TOOL_BIN" "$TEST_TRASH" "$STAGE/bin"
bash "$ROOT_DIR/script/stage_bridge_resources.sh" "$ROOT_DIR/vendor/mole" "$STAGE"

# Delay only the two bounded discovery walks per root. Validation calls use a
# different find shape and therefore remain representative of normal work.
printf '%s\n' '#!/bin/bash' \
    'for arg in "$@"; do' \
    '    if [[ "$arg" == "-mindepth" ]]; then sleep "${SM_TEST_FIND_DELAY:-0}"; break; fi' \
    'done' \
    'exec /usr/bin/find "$@"' > "$TOOL_BIN/find"
chmod +x "$TOOL_BIN/find"
printf '%s\n' '#!/bin/bash' 'exit 1' > "$IDLE_LSOF"
chmod +x "$IDLE_LSOF"

declare -a TEST_ROOTS=()
for index in 0 1 2 3; do
    project="$TEST_HOME/Projects/project-$index"
    artifact="$project/.next"
    mkdir -p "$artifact/cache"
    printf '%s\n' '{"name":"purge-concurrency-fixture"}' > "$project/package.json"
    printf '%s\n' "fixture-$index" > "$artifact/cache/data"
    /usr/bin/touch -t 202001010000 "$project" "$project/package.json" \
        "$artifact" "$artifact/cache" "$artifact/cache/data"
    TEST_ROOTS+=("$project")
done
printf '%s\n' "${TEST_ROOTS[@]}" > "$TEST_HOME/.config/mole/purge_paths"

run_scan() {
    local jobs="$1"
    local output="$2"
    env HOME="$TEST_HOME" USER="${USER:-tester}" LOGNAME="${LOGNAME:-tester}" \
        XDG_CACHE_HOME="$TEST_CACHE" PATH="$TOOL_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
        TMPDIR="$TEST_ROOT" FORGESWEEP_FULL_DISK_AUTHORIZED=1 MOLE_TEST_MODE=1 \
        MOLE_TEST_TRASH_DIR="$TEST_TRASH" MOLE_DELETE_LOG="$TEST_ROOT/deletions.log" \
        SM_LSOF_BIN="$IDLE_LSOF" MO_USE_FIND=1 SM_TEST_FIND_DELAY=0.20 \
        SM_PURGE_MAX_SCAN_JOBS="$jobs" bash "$STAGE/bin/app_purge_scan.sh" \
        > "$output" 2> "$output.err"
}

elapsed_scan() {
    local jobs="$1"
    local output="$2"
    local start finish
    start=$(/usr/bin/perl -MTime::HiRes=time -e 'printf "%.6f", time')
    run_scan "$jobs" "$output"
    finish=$(/usr/bin/perl -MTime::HiRes=time -e 'printf "%.6f", time')
    /usr/bin/awk -v start="$start" -v finish="$finish" \
        'BEGIN { printf "%.3f", finish - start }'
}

SERIAL_OUT="$TEST_ROOT/serial.out"
PARALLEL_OUT="$TEST_ROOT/parallel.out"
serial_elapsed=$(elapsed_scan 1 "$SERIAL_OUT")
parallel_elapsed=$(elapsed_scan 4 "$PARALLEL_OUT")

for project in "${TEST_ROOTS[@]}"; do
    artifact="$project/.next"
    grep -Fq "$artifact" "$SERIAL_OUT" || {
        echo "not ok - serial scan dropped $artifact" >&2
        cat "$SERIAL_OUT.err" >&2 || true
        exit 1
    }
    grep -Fq "$artifact" "$PARALLEL_OUT" || {
        echo "not ok - parallel scan dropped $artifact" >&2
        cat "$PARALLEL_OUT.err" >&2 || true
        exit 1
    }
done

# Results are consumed in configured-root order even though discovery runs in
# batches. Check both scans to guard against completion-order regressions.
serial_first=$(grep -n -F "${TEST_ROOTS[0]}/.next" "$SERIAL_OUT" | head -1 | cut -d: -f1)
serial_last=$(grep -n -F "${TEST_ROOTS[3]}/.next" "$SERIAL_OUT" | head -1 | cut -d: -f1)
parallel_first=$(grep -n -F "${TEST_ROOTS[0]}/.next" "$PARALLEL_OUT" | head -1 | cut -d: -f1)
parallel_last=$(grep -n -F "${TEST_ROOTS[3]}/.next" "$PARALLEL_OUT" | head -1 | cut -d: -f1)
[[ "$serial_first" =~ ^[0-9]+$ && "$serial_last" =~ ^[0-9]+$ &&
   "$parallel_first" =~ ^[0-9]+$ && "$parallel_last" =~ ^[0-9]+$ &&
   "$serial_first" -lt "$serial_last" && "$parallel_first" -lt "$parallel_last" ]] || {
    echo "not ok - scan result order changed" >&2
    exit 1
}

# Four roots with two delayed walks each should be materially faster with the
# explicit four-worker pool. Keep a generous ratio for busy developer hosts.
/usr/bin/awk -v serial="$serial_elapsed" -v parallel="$parallel_elapsed" \
    'BEGIN { exit !(serial > 1.0 && parallel < serial * 0.80) }' || {
    echo "not ok - bounded root scans did not reduce elapsed time (serial=${serial_elapsed}s parallel=${parallel_elapsed}s)" >&2
    exit 1
}

printf 'ok - bounded purge root scans preserve results and order (serial=%ss parallel=%ss)\n' \
    "$serial_elapsed" "$parallel_elapsed"
